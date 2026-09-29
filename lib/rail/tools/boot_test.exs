defmodule Rail.Tools.BootTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Boot
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.FollowerRegistry
  alias Rail.Tools.FollowerSupervisor
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Tools.Schemas.Restart

  # Boot adopts real OS processes, so these run real children.
  @moduletag :real_spawn

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "boot_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    # Adoption hands the row to a Follower, which reads the stream format off the
    # run's role, so every run here needs a real role behind it.
    {:ok, backend} =
      Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    project =
      %Project{}
      |> Project.changeset(%{
        name: "Boot Project",
        github_repo: "org/boot-#{System.unique_integer([:positive])}",
        github_installation_id: System.unique_integer([:positive]),
        linear_team_key: "BOO",
        default_branch: "main",
        clone_path: Path.join(tmp_dir, "clone")
      })
      |> Repo.insert!()

    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        backend_id: backend.id,
        stage: :engineer,
        name: "boot role",
        model: "claude-opus-5-5",
        system_prompt: "You are the engineer."
      })

    %{tmp_dir: tmp_dir, backend: backend, project: project, role: role}
  end

  test "adopts live child process, starts Follower and replays stream", %{tmp_dir: tmp_dir, role: role} do
    run =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    stream_path = Path.join(tmp_dir, "live_adopt.ndjson")
    line1 = ~s({"type":"system","session_id":"sess-live-adopt"})
    File.write!(stream_path, "#{line1}\n")
    File.write!("#{stream_path}.err", "")

    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["10"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    %OsProcess{id: os_process_id} =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: stream_path,
        status: :running,
        os_pid: pid,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    results = Boot.reconcile()
    assert [{:adopted_live, %OsProcess{id: ^os_process_id}, follower_pid}] = results
    assert is_pid(follower_pid)
    assert Process.alive?(follower_pid)

    # Calling adopt again sees it is already followed
    repeat = Boot.reconcile()
    assert [{:already_following, _run, ^follower_pid}] = repeat

    FollowerSupervisor.stop_follower(follower_pid)
    Tools.terminate_os_process(pid, grace_period: 50)
  end

  test "a live process adopted again resumes past what its last Follower logged", %{tmp_dir: tmp_dir, role: role} do
    run =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run.id}")

    stream_path = Path.join(tmp_dir, "resume_live.ndjson")
    line1 = ~s({"type":"system","subtype":"init","session_id":"sess-resume-live"})
    line2 = ~s({"type":"assistant","message":{"content":[{"type":"text","text":"not logged yet"}]}})
    File.write!(stream_path, "#{line1}\n#{line2}\n")
    File.write!("#{stream_path}.err", "")

    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["10"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    %OsProcess{}
    |> OsProcess.changeset(%{
      run_id: run.id,
      task_id: run.task_id,
      stream_path: stream_path,
      status: :running,
      os_pid: pid,
      stream_offset: byte_size(line1) + 1,
      started_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert [{:adopted_live, %OsProcess{}, follower_pid}] = Boot.reconcile()

    assert_receive {:run_events, _run_id, [%{line: ^line2}]}, 5_000
    assert [^line2] = Enum.map(Pipeline.list_run_events(run), & &1.line)

    FollowerSupervisor.stop_follower(follower_pid)
    Tools.terminate_os_process(pid, grace_period: 50)
  end

  test "a dead process has the lines nobody logged written before it settles", %{tmp_dir: tmp_dir, role: role} do
    run =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    stream_path = Path.join(tmp_dir, "resume_dead.ndjson")
    line1 = ~s({"type":"system","subtype":"init","session_id":"sess-resume-dead"})
    line2 = ~s({"type":"result","subtype":"success","session_id":"sess-resume-dead","usage":{"input_tokens":1}})
    File.write!(stream_path, "#{line1}\n#{line2}\n")
    File.write!("#{stream_path}.err", "")

    %OsProcess{}
    |> OsProcess.changeset(%{
      run_id: run.id,
      task_id: run.task_id,
      stream_path: stream_path,
      status: :running,
      os_pid: 999_997,
      stream_offset: byte_size(line1) + 1,
      started_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert [{:adopted_dead, %OsProcess{}}] = Boot.reconcile()

    assert [^line2] = Enum.map(Pipeline.list_run_events(run), & &1.line)
    assert {:ok, %Run{status: :finished, conversation_id: "sess-resume-dead"}} = Pipeline.get_run(run.id)
  end

  test "settles dead child process as finished while unwatched", %{tmp_dir: tmp_dir, role: role} do
    run =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    stream_path = Path.join(tmp_dir, "dead_adopt.ndjson")

    line1 =
      ~s({"type":"result","subtype":"success","session_id":"sess-dead-1","usage":{"input_tokens":150,"output_tokens":75}})

    File.write!(stream_path, "#{line1}\n")
    File.write!("#{stream_path}.err", "")

    dead_pid = 999_998

    _run =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: stream_path,
        status: :running,
        os_pid: dead_pid,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    results = Boot.reconcile()
    assert [{:adopted_dead, %OsProcess{status: :adopted_dead}}] = results

    # Run should be settled
    {:ok, settled_run} = Pipeline.get_run(run.id)
    assert settled_run.status == :finished
    assert settled_run.exit_code == 0
    assert settled_run.conversation_id == "sess-dead-1"
    assert settled_run.usage.input_tokens == 150
  end

  test "settles dead child process with no result as failure with transient pattern", %{
    tmp_dir: tmp_dir,
    role: role
  } do
    run =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    stream_path = Path.join(tmp_dir, "no_result.ndjson")
    File.write!(stream_path, ~s({"type":"system","session_id":"sess-incomplete"}\n))
    File.write!("#{stream_path}.err", "")

    _run =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: stream_path,
        status: :running,
        os_pid: 999_997,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    results = Boot.reconcile()
    assert [{:adopted_dead, %OsProcess{status: :adopted_dead}}] = results

    {:ok, settled_run} = Pipeline.get_run(run.id)
    assert settled_run.status == :finished
    assert settled_run.exit_code == -1
    assert settled_run.error =~ "without reporting a result"
  end

  test "starting run without PID times out and fails after 60s", %{tmp_dir: tmp_dir, role: role} do
    run =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: role.id,
        status: :starting,
        started_at: DateTime.shift(DateTime.utc_now(), second: -70)
      })
      |> Repo.insert!()

    stream_path = Path.join(tmp_dir, "stalled_starting.ndjson")
    File.write!(stream_path, "")
    File.write!("#{stream_path}.err", "")

    _run =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: stream_path,
        status: :starting,
        os_pid: nil,
        started_at: DateTime.shift(DateTime.utc_now(), second: -70)
      })
      |> Repo.insert!()

    results = Boot.reconcile(timeout_seconds: 60)
    assert [{:failed_starting, %OsProcess{status: :finished}}] = results

    {:ok, settled_run} = Pipeline.get_run(run.id)
    assert settled_run.status == :finished
    assert settled_run.error =~ "Spawn timed out"
  end

  test "starting run within timeout is left alone", %{tmp_dir: tmp_dir, role: role} do
    run =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: role.id,
        status: :starting,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    stream_path = Path.join(tmp_dir, "fresh_starting.ndjson")
    File.write!(stream_path, "")
    File.write!("#{stream_path}.err", "")

    %OsProcess{id: os_process_id} =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: stream_path,
        status: :starting,
        os_pid: nil,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    results = Boot.reconcile(timeout_seconds: 60)
    assert [{:still_starting, %OsProcess{id: ^os_process_id}}] = results
  end

  test "ignores a process that has already finished", %{tmp_dir: tmp_dir, role: role} do
    run =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    stream_path = Path.join(tmp_dir, "finished.ndjson")
    File.write!(stream_path, "")
    File.write!("#{stream_path}.err", "")

    Repo.insert!(%OsProcess{
      run_id: run.id,
      task_id: run.task_id,
      stream_path: stream_path,
      status: :finished,
      os_pid: 999_991,
      started_at: DateTime.utc_now()
    })

    assert Boot.reconcile() == []
  end

  test "start_link/1 stays out of the tree while adoption on boot is off" do
    assert Boot.start_link([]) == :ignore
  end

  test "start_link/1 reconciles as a task when adoption on boot is enabled" do
    stub(Application, :get_env, fn
      :rail, :adopt_on_boot, _default -> true
      app, key, default -> call_original(Application, :get_env, [app, key, default])
    end)

    {:ok, pid} = Boot.start_link([])
    assert is_pid(pid)

    # The task finishes and exits normally, when the scheduler gets to it.
    eventually(fn -> refute Process.alive?(pid) end)
  end

  test "settles dead run with various error and stderr combinations", %{tmp_dir: tmp_dir, role: role} do
    # Case 1: both result_error and stderr
    run1 =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    stream1 = Path.join(tmp_dir, "err1.ndjson")
    File.write!(stream1, ~s({"type":"result","subtype":"error","is_error":true}\n))
    File.write!("#{stream1}.err", "stderr log output\n\n")

    Repo.insert!(%OsProcess{
      run_id: run1.id,
      task_id: run1.task_id,
      stream_path: stream1,
      status: :running,
      os_pid: 999_980,
      started_at: DateTime.utc_now()
    })

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run1.id}")

    Boot.reconcile()

    assert_receive {:os_process_finished, _run, outcome1}, 500
    assert outcome1.error =~ "claude reported error"
    assert outcome1.error =~ "stderr log output"

    # Case 2: result_error only (no stderr)
    run2 =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    stream2 = Path.join(tmp_dir, "err2.ndjson")
    File.write!(stream2, ~s({"type":"result","subtype":"error_max_turns","is_error":true}\n))
    File.write!("#{stream2}.err", "")

    Repo.insert!(%OsProcess{
      run_id: run2.id,
      task_id: run2.task_id,
      stream_path: stream2,
      status: :running,
      os_pid: 999_981,
      started_at: DateTime.utc_now()
    })

    Boot.reconcile()
    {:ok, r2} = Pipeline.get_run(run2.id)
    assert r2.error == "claude reported error_max_turns"

    # Case 3: stderr only, saw_result was true
    run3 =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    stream3 = Path.join(tmp_dir, "err3.ndjson")
    File.write!(stream3, ~s({"type":"result","subtype":"success"}\n))
    File.write!("#{stream3}.err", "only stderr output\n")

    Repo.insert!(%OsProcess{
      run_id: run3.id,
      task_id: run3.task_id,
      stream_path: stream3,
      status: :running,
      os_pid: 999_982,
      started_at: DateTime.utc_now()
    })

    Boot.reconcile()
    {:ok, r3} = Pipeline.get_run(run3.id)
    assert r3.error == "only stderr output"

    # Case 4: stream path does not exist
    run4 =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    %OsProcess{id: run4_id} =
      Repo.insert!(%OsProcess{
        run_id: run4.id,
        task_id: run4.task_id,
        stream_path: Path.join(tmp_dir, "nonexistent.ndjson"),
        status: :running,
        os_pid: 999_983,
        started_at: DateTime.utc_now()
      })

    assert [{:adopted_dead, %OsProcess{id: ^run4_id}}] = Boot.reconcile()
  end

  test "settles a dead command from the status it wrote on its way out", %{tmp_dir: tmp_dir, role: role} do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    stream_path = Path.join(tmp_dir, "dead_command.log")
    File.write!(stream_path, "copied the database\n")
    File.write!("#{stream_path}.exit", "0\n")

    %OsProcess{}
    |> OsProcess.changeset(%{
      run_id: run.id,
      task_id: run.task_id,
      kind: :setup,
      stream_path: stream_path,
      status: :running,
      os_pid: 999_997,
      started_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert [{:adopted_dead, %OsProcess{exit_code: 0}}] = Boot.reconcile()
    assert {:ok, %Run{status: :finished, exit_code: 0, error: nil}} = Pipeline.get_run(run.id)
    assert [%{line: "copied the database"}] = Pipeline.list_run_events(run)
  end

  test "a dead command that never wrote how it exited is a failure", %{tmp_dir: tmp_dir, role: role} do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    stream_path = Path.join(tmp_dir, "killed_command.log")
    File.write!(stream_path, "")

    %OsProcess{}
    |> OsProcess.changeset(%{
      run_id: run.id,
      task_id: run.task_id,
      kind: :setup,
      stream_path: stream_path,
      status: :running,
      os_pid: 999_996,
      started_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert [{:adopted_dead, %OsProcess{exit_code: -1}}] = Boot.reconcile()

    assert {:ok, %Run{exit_code: -1, error: "Ended while Rail was not watching it, without recording how it exited."}} =
             Pipeline.get_run(run.id)
  end

  test "a dead command that failed keeps the status it failed with", %{tmp_dir: tmp_dir, role: role} do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    stream_path = Path.join(tmp_dir, "failed_command.log")
    File.write!(stream_path, "")
    File.write!("#{stream_path}.exit", "2\n")

    %OsProcess{}
    |> OsProcess.changeset(%{
      run_id: run.id,
      task_id: run.task_id,
      kind: :setup,
      stream_path: stream_path,
      status: :running,
      os_pid: 999_995,
      started_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert [{:adopted_dead, %OsProcess{exit_code: 2}}] = Boot.reconcile()
    assert {:ok, %Run{exit_code: 2, error: "Exited with code 2"}} = Pipeline.get_run(run.id)
  end

  describe "a Docker sandbox Rail restarted under" do
    # A run that settles needs a real task behind it.
    setup %{project: project, role: role, tmp_dir: tmp_dir} do
      issue =
        %Issue{}
        |> Issue.changeset(%{
          project_id: project.id,
          external_id: "lin_boot_#{System.unique_integer([:positive])}",
          identifier: "BOO-#{System.unique_integer([:positive])}",
          title: "Boot Issue",
          state: :backlog
        })
        |> Repo.insert!()

      task =
        %Task{}
        |> Task.changeset(
          %{
            issue_id: issue.id,
            stage: :engineer,
            worktree_name: "boot-#{System.unique_integer([:positive])}",
            worktree_path: Path.join(tmp_dir, "worktree"),
            scratch_path: Path.join(tmp_dir, "scratch")
          },
          project.id
        )
        |> Repo.insert!()

      {:ok, run} =
        Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

      %{run: run}
    end

    test "is adopted, and the conversation says Rail restarted between what came before and after", %{
      run: run,
      tmp_dir: tmp_dir
    } do
      Repo.insert!(%Restart{stopped_at: DateTime.shift(DateTime.utc_now(), second: -41)})
      {:ok, state} = Agent.start_link(fn -> %{"Running" => true} end)

      Req.Test.stub(Docker, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/containers/c-live/json"} -> Req.Test.json(conn, %{"State" => Agent.get(state, & &1)})
          {"DELETE", "/containers/c-live"} -> Plug.Conn.send_resp(conn, 204, "")
        end
      end)

      stream_path = Path.join(tmp_dir, "live_docker.ndjson")
      before = ~s({"type":"system","subtype":"init","session_id":"sess-docker"})
      during = ~s({"type":"assistant","message":{"content":[{"type":"text","text":"written while Rail was away"}]}})
      File.write!(stream_path, "#{before}\n#{during}\n")
      File.write!("#{stream_path}.err", "")

      os_process =
        Repo.insert!(%OsProcess{
          run_id: run.id,
          task_id: run.task_id,
          stream_path: stream_path,
          status: :running,
          runtime: :docker,
          container_id: "c-live",
          stream_offset: byte_size(before) + 1,
          started_at: DateTime.utc_now(),
          reserved_cpus: 1,
          reserved_memory_gb: 2
        })

      Pipeline.append_run_events(run.id, os_process.id, [before])
      Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run.id}")

      # Lazily, so the Follower adoption starts has it from its first tick, and again if it restarts.
      Req.Test.allow(Docker, self(), fn -> GenServer.whereis({:via, Registry, {FollowerRegistry, os_process.id}}) end)

      assert [{:adopted_live, %OsProcess{}, _follower_pid}] = Boot.reconcile(boot: true)

      restarted =
        "[rail] Rail restarted while this turn was running. The boot role kept working in its sandbox, " <>
          "and everything it wrote while Rail was away is below."

      eventually(fn ->
        assert [^before, ^restarted, ^during] = Enum.map(Pipeline.list_run_events(run), & &1.line)
      end)

      assert %OsProcess{restarts: 1} = Repo.reload!(os_process)
      assert [%Restart{stopped_at: %DateTime{}, started_at: %DateTime{}, sandboxes_kept: 1}] = Tools.list_restarts()

      result = ~s({"type":"result","subtype":"success","session_id":"sess-docker","usage":{"input_tokens":7}})
      File.write!(stream_path, "#{result}\n", [:append])
      Agent.update(state, fn _running -> %{"Running" => false, "ExitCode" => 0, "OOMKilled" => false} end)

      assert_receive {:os_process_finished, %OsProcess{exit_code: 0}, %{error: nil}}, 5_000
      assert {:ok, %Run{status: :finished, exit_code: 0, usage: %Run.Usage{input_tokens: 7}}} = Pipeline.get_run(run.id)
    end

    test "that exited while Rail was away settles from how its container exited, and the whole stream", %{
      run: run,
      tmp_dir: tmp_dir
    } do
      Req.Test.stub(Docker, fn conn ->
        Req.Test.json(conn, %{"State" => %{"Running" => false, "ExitCode" => 0, "OOMKilled" => false}})
      end)

      stream_path = Path.join(tmp_dir, "exited_docker.ndjson")
      File.write!(stream_path, ~s({"type":"system","session_id":"sess-exited"}\n))
      File.write!("#{stream_path}.err", "")

      Repo.insert!(%OsProcess{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: stream_path,
        status: :running,
        runtime: :docker,
        container_id: "c-exited",
        started_at: DateTime.utc_now()
      })

      Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run.id}")

      assert [{:adopted_dead, %OsProcess{exit_code: 0, ended_reason: :finished}}] = Boot.reconcile(boot: true)
      assert_received {:os_process_finished, %OsProcess{}, %{exit_code: 0, error: nil}}

      assert [
               "[rail] Rail restarted while this turn was running." <> _kept_working,
               ~s({"type":"system","session_id":"sess-exited"})
             ] = Enum.map(Pipeline.list_run_events(run), & &1.line)
    end

    test "that ran out of memory while Rail was away says so", %{run: run, tmp_dir: tmp_dir} do
      Req.Test.stub(Docker, fn conn ->
        Req.Test.json(conn, %{"State" => %{"Running" => false, "ExitCode" => 137, "OOMKilled" => true}})
      end)

      stream_path = Path.join(tmp_dir, "oom_docker.ndjson")
      File.write!(stream_path, "")
      File.write!("#{stream_path}.err", "")

      Repo.insert!(%OsProcess{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: stream_path,
        status: :running,
        runtime: :docker,
        container_id: "c-oom",
        started_at: DateTime.utc_now(),
        reserved_cpus: 2,
        reserved_memory_gb: 4
      })

      assert [{:adopted_dead, %OsProcess{exit_code: 137, ended_reason: :out_of_memory}}] = Boot.reconcile()
      assert {:ok, %Run{error: "Killed: it used more than the 4 GB its role reserves."}} = Pipeline.get_run(run.id)
    end

    test "running CI keeps its own words, and its exit file is its result", %{run: run, tmp_dir: tmp_dir} do
      Req.Test.stub(Docker, fn conn ->
        Req.Test.json(conn, %{"State" => %{"Running" => false, "ExitCode" => 3, "OOMKilled" => false}})
      end)

      stream_path = Path.join(tmp_dir, "ci_docker.log")
      File.write!(stream_path, "3 tests, 1 failure\n")
      File.write!("#{stream_path}.exit", "3\n")

      Repo.insert!(%OsProcess{
        run_id: run.id,
        task_id: run.task_id,
        kind: :ci,
        stream_path: stream_path,
        status: :running,
        runtime: :docker,
        container_id: "c-ci",
        started_at: DateTime.utc_now()
      })

      assert [{:adopted_dead, %OsProcess{exit_code: 3}}] = Boot.reconcile(boot: true)

      assert [
               "[rail] Rail restarted while CI was running. It kept running in its sandbox, " <>
                 "and everything it wrote while Rail was away is below.",
               "3 tests, 1 failure" | _settled
             ] = Enum.map(Pipeline.list_run_events(run), & &1.line)
    end

    test "that exited while Rail was away says what went wrong, as its Follower would have", %{
      role: role,
      tmp_dir: tmp_dir
    } do
      Req.Test.stub(Docker, fn
        %{method: "DELETE"} = conn ->
          Plug.Conn.send_resp(conn, 204, "")

        %{request_path: "/containers/" <> rest} = conn ->
          code = rest |> String.split("/") |> hd() |> String.replace_prefix("c-code-", "") |> String.to_integer()
          Req.Test.json(conn, %{"State" => %{"Running" => false, "ExitCode" => code, "OOMKilled" => false}})
      end)

      result_error = ~s({"type":"result","subtype":"error","is_error":true,"result":"It broke"})

      cases = [
        {1, result_error, "warn", "claude reported error: It broke\nwarn", :finished},
        {2, result_error, "", "claude reported error: It broke", :finished},
        {3, "", "only stderr", "only stderr", :finished},
        {137, "", "", "Exited with code 137", :killed}
      ]

      for {code, line, stderr, error, ended_reason} <- cases do
        {:ok, run} =
          Pipeline.create_run(%{
            task_id: UXID.generate!(prefix: "tsk"),
            role_id: role.id,
            status: :running,
            started_at: DateTime.utc_now()
          })

        stream_path = Path.join(tmp_dir, "code_#{code}.ndjson")
        File.write!(stream_path, if(line == "", do: "", else: "#{line}\n"))
        File.write!("#{stream_path}.err", stderr)

        Repo.insert!(%OsProcess{
          run_id: run.id,
          task_id: run.task_id,
          stream_path: stream_path,
          status: :running,
          runtime: :docker,
          container_id: "c-code-#{code}",
          started_at: DateTime.utc_now()
        })

        assert [{:adopted_dead, %OsProcess{exit_code: ^code, ended_reason: ^ended_reason}}] = Boot.reconcile()
        assert {:ok, %Run{error: ^error}} = Pipeline.get_run(run.id)
      end
    end

    test "a container Docker no longer has is settled as ended, and one it cannot answer for keeps running", %{
      run: run,
      tmp_dir: tmp_dir
    } do
      Req.Test.stub(Docker, fn
        %{request_path: "/containers/c-removed/json"} = conn ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "No such container"})

        %{request_path: "/containers/c-silent/json"} = conn ->
          Req.Test.transport_error(conn, :timeout)

        %{method: "DELETE"} = conn ->
          Plug.Conn.send_resp(conn, 204, "")
      end)

      stream_path = Path.join(tmp_dir, "silent.ndjson")
      File.write!(stream_path, "")

      [_removed, silent] =
        for container_id <- ["c-removed", "c-silent"] do
          Repo.insert!(%OsProcess{
            run_id: run.id,
            task_id: run.task_id,
            stream_path: stream_path,
            status: :running,
            runtime: :docker,
            container_id: container_id,
            started_at: DateTime.utc_now()
          })
        end

      Req.Test.allow(Docker, self(), fn -> GenServer.whereis({:via, Registry, {FollowerRegistry, silent.id}}) end)

      assert [{:adopted_dead, %OsProcess{container_id: "c-removed"}}, {:adopted_live, %OsProcess{}, follower_pid}] =
               Enum.sort_by(Boot.reconcile(boot: true), &elem(&1, 0))

      FollowerSupervisor.stop_follower(follower_pid)
    end

    test "is picked up on the minute pass without saying Rail restarted", %{run: run, tmp_dir: tmp_dir} do
      Req.Test.stub(Docker, fn conn -> Req.Test.json(conn, %{"State" => %{"Running" => true}}) end)
      stream_path = Path.join(tmp_dir, "minute_docker.ndjson")
      File.write!(stream_path, "")

      os_process =
        Repo.insert!(%OsProcess{
          run_id: run.id,
          task_id: run.task_id,
          stream_path: stream_path,
          status: :running,
          runtime: :docker,
          container_id: "c-minute",
          started_at: DateTime.utc_now()
        })

      Req.Test.allow(Docker, self(), fn -> GenServer.whereis({:via, Registry, {FollowerRegistry, os_process.id}}) end)

      assert [{:adopted_live, %OsProcess{}, follower_pid}] = Boot.reconcile()
      FollowerSupervisor.stop_follower(follower_pid)

      assert [] = Pipeline.list_run_events(run)
      assert %OsProcess{restarts: 0} = Repo.reload!(os_process)
    end
  end

  test "a boot with no stop on record was a crash, and is recorded as a restart all the same" do
    assert [] = Boot.reconcile(boot: true)
    assert [%Restart{stopped_at: nil, started_at: %DateTime{}, sandboxes_kept: 0}] = Tools.list_restarts()
  end

  describe "in Docker" do
    setup do: stub_sandbox_config(runtime: :docker)

    test "removes the containers of sandboxes that have settled, and leaves the rest", %{role: role} do
      {:ok, run} =
        Pipeline.create_run(%{
          task_id: UXID.generate!(prefix: "tsk"),
          role_id: role.id,
          status: :running,
          started_at: DateTime.utc_now()
        })

      settled =
        Repo.insert!(%OsProcess{
          run_id: run.id,
          task_id: run.task_id,
          stream_path: "/dev/null",
          status: :finished,
          started_at: DateTime.utc_now()
        })

      test_pid = self()

      Req.Test.stub(Docker, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/info"} ->
            Req.Test.json(conn, %{"NCPU" => 4, "MemTotal" => 8 * 1024 ** 3})

          {"GET", "/containers/json"} ->
            Req.Test.json(conn, [
              %{"Id" => "c-settled", "Labels" => %{"dev.railai.sandbox" => settled.id}},
              %{"Id" => "c-unknown", "Labels" => %{"dev.railai.sandbox" => "proc_nobody"}}
            ])

          {"DELETE", "/containers/" <> id} ->
            send(test_pid, {:removed, id})
            Plug.Conn.send_resp(conn, 204, "")
        end
      end)

      assert [] = Boot.reconcile()
      assert_received {:removed, "c-settled"}
      assert_received {:removed, "c-unknown"}
    end
  end
end
