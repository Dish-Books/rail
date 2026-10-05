defmodule Rail.Tools.Actions.StartOsProcessTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.FollowerSupervisor
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Tools.Workers.StartAfterUsageReset

  # These tests are about the spawn itself, so they run real children.
  @moduletag :real_spawn

  setup %{project: project} do
    scope = system_scope()
    unique = System.unique_integer([:positive])

    tmp_dir = Path.join(System.tmp_dir!(), "start_run_test_#{unique}")
    worktree_path = Path.join(tmp_dir, "worktree")
    scratch_path = Path.join(tmp_dir, "scratch")
    File.mkdir_p!(worktree_path)
    File.mkdir_p!(scratch_path)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    # The executable is whatever the account the turn is placed on points at, and
    # only this one offers the role's model, so a test that wants to spawn
    # something else repoints this row before calling start_os_process.
    model = "claude-start-#{unique}"
    backend = ready_backend(model, [], %{executable_path: "/bin/sleep"})

    {:ok, seeded_role} = Roles.get_role(project_id: project.id, stage: :engineer)
    {:ok, role} = Roles.update_role(scope, seeded_role, %{model: model})

    issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_start_run_#{unique}",
        identifier: "SR#{unique}-1",
        title: "Start Run Issue",
        state: :backlog
      })
      |> Repo.insert!()

    {:ok, task} =
      %Task{id: UXID.generate!(prefix: "tsk")}
      |> Task.changeset(
        %{
          issue_id: issue.id,
          stage: :engineer,
          worktree_name: "start-run-#{unique}",
          worktree_path: worktree_path,
          scratch_path: scratch_path
        },
        project.id
      )
      |> Repo.insert()

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :starting,
        started_at: DateTime.utc_now()
      })

    %{
      backend: backend,
      model: model,
      role: role,
      run: run,
      scratch_path: scratch_path,
      scope: scope,
      worktree_path: worktree_path
    }
  end

  test "spawns child, records runs row, sets os_pid and running status", %{run: run} do
    expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

    {:ok, os_process} = Tools.start_os_process(run, ["2"])

    assert %OsProcess{} = os_process
    assert os_process.run_id == run.id
    assert os_process.task_id == run.task_id
    assert os_process.status == :running
    assert is_integer(os_process.os_pid)
    assert os_process.os_pid > 0
    assert Tools.os_process_alive?(os_process.os_pid)

    Tools.terminate_os_process(os_process.os_pid, grace_period: 100)
  end

  # Every turn is pointed at Rail and given a token for it, whatever its role is
  # allowed: what it may actually call is decided on Rail's side, per call.
  # Deciding it twice is how a QA turn ended up told to connect with no token and
  # got a 401 on its first call.
  test "gives every turn a run token in its environment, and records only its hash", %{run: run} do
    test_pid = self()

    expect(Tools, :spawn_os_process, fn _executable, _args, opts ->
      send(test_pid, {:env, Keyword.fetch!(opts, :env)})
      {:ok, nil, 4242}
    end)

    expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

    assert {:ok, %OsProcess{id: os_process_id}} = Tools.start_os_process(run, ["2"])
    assert_received {:env, %{"RAIL_MCP_TOKEN" => token}}

    hash = :crypto.hash(:sha256, token)
    assert %OsProcess{mcp_token_hash: ^hash} = Repo.get!(OsProcess, os_process_id)
  end

  test "tells the agent which ports its worktree owns", %{run: run} do
    {:ok, _task} = Pipeline.update_task(Repo.get!(Task, run.task_id), %{worktree_slot: 2})
    test_pid = self()

    expect(Tools, :spawn_os_process, fn _executable, _args, opts ->
      send(test_pid, {:env, Keyword.fetch!(opts, :env)})
      {:ok, nil, 4242}
    end)

    expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

    assert {:ok, %OsProcess{}} = Tools.start_os_process(run, ["2"])
    assert_received {:env, %{"RAIL_WORKTREE_SLOT" => "2", "RAIL_PORT_BASE" => "20200"}}
  end

  # A token is good only while its turn is, so the next turn cannot be driven
  # with the last one's.
  test "a second turn gets a token of its own", %{run: run} do
    test_pid = self()

    stub(Tools, :spawn_os_process, fn _executable, _args, opts ->
      send(test_pid, {:env, Keyword.fetch!(opts, :env)})
      {:ok, nil, 4243}
    end)

    stub(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

    {:ok, %OsProcess{} = first} = Tools.start_os_process(run, ["2"])
    assert_received {:env, %{"RAIL_MCP_TOKEN" => first_token}}

    {:ok, _finished} = Tools.stop_os_process(system_scope(), first)
    {:ok, %OsProcess{}} = Tools.start_os_process(run, ["2"])
    assert_received {:env, %{"RAIL_MCP_TOKEN" => second_token}}

    refute first_token == second_token
  end

  test "writes the stream under the task's scratch directory, one file per run", %{
    run: run,
    scratch_path: scratch_path
  } do
    expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

    {:ok, os_process} = Tools.start_os_process(run, ["2"])

    assert os_process.stream_path == Path.join([scratch_path, "streams", "#{run.id}.ndjson"])
    assert File.exists?(os_process.stream_path)
    assert File.exists?("#{os_process.stream_path}.err")

    Tools.terminate_os_process(os_process.os_pid, grace_period: 100)
  end

  test "runs the child in the task's worktree and points it at the stream files", %{
    backend: backend,
    run: run,
    scope: scope,
    worktree_path: worktree_path
  } do
    {:ok, _backend} = Tools.update_backend(scope, backend, %{executable_path: "/bin/sh"})

    script = ~s(printf '{"cwd":"%s"}\n' "$PWD")

    expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

    {:ok, os_process} = Tools.start_os_process(run, ["-c", script])

    content =
      Enum.reduce_while(1..200, "", fn _i, _acc ->
        content = if File.exists?(os_process.stream_path), do: File.read!(os_process.stream_path), else: ""

        if content =~ Path.basename(worktree_path) do
          {:halt, content}
        else
          Process.sleep(10)
          {:cont, content}
        end
      end)

    assert content =~ Path.basename(worktree_path)

    Tools.terminate_os_process(os_process.os_pid, grace_period: 50)
  end

  test "runs the child as the account in the backend's config directory", %{
    backend: backend,
    run: run,
    scope: scope
  } do
    {:ok, backend} = Tools.update_backend(scope, backend, %{executable_path: "/bin/sh"})
    config_dir = Backend.config_dir(backend)

    expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

    {:ok, os_process} = Tools.start_os_process(run, ["-c", ~s(printf '%s\n' "$CLAUDE_CONFIG_DIR")])

    content =
      Enum.reduce_while(1..200, "", fn _i, _acc ->
        content = File.read!(os_process.stream_path)

        if content =~ config_dir do
          {:halt, content}
        else
          Process.sleep(10)
          {:cont, content}
        end
      end)

    assert content == config_dir <> "\n"

    Tools.terminate_os_process(os_process.os_pid, grace_period: 50)
  end

  test "trusts the project's clone and the task's worktree in the backend's config", %{
    backend: backend,
    project: project,
    run: run,
    worktree_path: worktree_path
  } do
    expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

    {:ok, os_process} = Tools.start_os_process(run, ["5"])

    %{"projects" => projects} =
      backend |> Backend.config_dir() |> Path.join(".claude.json") |> File.read!() |> Jason.decode!()

    assert %{"hasTrustDialogAccepted" => true} = projects[project.clone_path]
    assert %{"hasTrustDialogAccepted" => true} = projects[worktree_path]

    Tools.terminate_os_process(os_process.os_pid, grace_period: 50)
  end

  # Linux refuses to exec with any one argument over 128KB, so a brief that inlines
  # an approved design's page used to die with E2BIG before the CLI ever ran.
  test "hands Claude its prompt on stdin, whatever its size", %{backend: backend, run: run, scope: scope} do
    {:ok, _backend} = Tools.update_backend(scope, backend, %{executable_path: "/bin/sh"})
    prompt = String.duplicate("design ", 40_000)

    expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

    # The shell stands in for the CLI: `-p` is a flag it accepts too, and `cat`
    # echoes whatever arrived on stdin into the stream.
    {:ok, os_process} = Tools.start_os_process(run, ["-p", prompt, "-c", "cat"])

    content =
      Enum.reduce_while(1..200, "", fn _i, _acc ->
        content = File.read!(os_process.stream_path)

        if byte_size(content) == byte_size(prompt) do
          {:halt, content}
        else
          Process.sleep(10)
          {:cont, content}
        end
      end)

    assert content == prompt
    assert File.read!("#{os_process.stream_path}.prompt") == prompt
  end

  # In argv the role prompt is in the agent's own command line, so a `pgrep -f`
  # for anything it mentions finds the agent, which then kills itself.
  test "hands Claude its role prompt in a file, out of its command line", %{run: run} do
    test_pid = self()

    expect(Tools, :spawn_os_process, fn _executable, args, opts ->
      send(test_pid, {:spawned, args, opts})
      {:ok, nil, 4245}
    end)

    expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

    {:ok, os_process} =
      Tools.start_os_process(run, [
        "-p",
        "the brief",
        "--append-system-prompt",
        "Start it with mix phx.server.",
        "--verbose"
      ])

    system_prompt_path = "#{os_process.stream_path}.system-prompt"
    assert_received {:spawned, ["-p", "--append-system-prompt-file", ^system_prompt_path, "--verbose"], _opts}
    assert File.read!(system_prompt_path) == "Start it with mix phx.server."
  end

  test "leaves the prompt in argv for other backends", %{backend: backend, role: role, run: run, scope: scope} do
    backend |> Ecto.Changeset.change(name: :agy) |> Repo.update!()
    {:ok, _role} = Roles.update_role(scope, role, %{cli: :agy})
    test_pid = self()

    expect(Tools, :spawn_os_process, fn _executable, args, opts ->
      send(test_pid, {:spawned, args, opts})
      {:ok, nil, 4244}
    end)

    expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

    {:ok, _os_process} = Tools.start_os_process(run, ["-p", "the prompt", "--model", "gemini"])

    assert_received {:spawned, ["-p", "the prompt", "--model", "gemini"], opts}
    refute Keyword.has_key?(opts, :stdin_path)
  end

  test "with a missing backend binary reports error and settles the run", %{
    backend: backend,
    run: run,
    scope: scope
  } do
    missing_bin = "/path/to/nonexistent/cli_binary_xyz"
    {:ok, _backend} = Tools.update_backend(scope, backend, %{executable_path: missing_bin})

    result = Tools.start_os_process(run, ["--help"])

    assert {:error, {:spawn_failed, {:missing_binary, ^missing_bin, %OsProcess{status: :finished}}, %Run{}}} =
             result

    reloaded_run = Repo.get!(Run, run.id)
    assert reloaded_run.status == :finished
    assert reloaded_run.exit_code == -1
    assert reloaded_run.error =~ "No such CLI binary"
  end

  test "a Follower that will not start fails the run with the reason", %{run: run} do
    expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:error, :no_follower} end)

    assert {:error, {:spawn_failed, :no_follower, %Run{error: "Failed to spawn runner: :no_follower"}}} =
             Tools.start_os_process(run, ["2"])

    %OsProcess{os_pid: os_pid} = Repo.get_by!(OsProcess, run_id: run.id)
    Tools.terminate_os_process(os_pid, grace_period: 100)
  end

  test "hands the spawned port and stream to a Follower", %{backend: %Backend{id: backend_id}, run: run} do
    test_pid = self()

    expect(FollowerSupervisor, :start_follower, fn followed, opts ->
      send(test_pid, {:followed, followed, opts})
      {:ok, test_pid}
    end)

    {:ok, os_process} = Tools.start_os_process(run, ["2"])

    # Everything the Follower needs rides on the row it is handed.
    assert_receive {:followed, followed, opts}
    assert followed.id == os_process.id
    assert followed.stream_path == os_process.stream_path
    assert followed.os_pid == os_process.os_pid
    assert followed.run.id == run.id
    assert followed.backend_id == backend_id
    assert is_port(opts[:port])

    Tools.terminate_os_process(os_process.os_pid, grace_period: 100)
  end

  describe "on a machine with too little free" do
    # Another run's sandbox holds what the test machine (4 CPUs, 8 GB) can reserve.
    setup %{run: run} do
      {:ok, other} =
        Pipeline.create_run(%{
          task_id: run.task_id,
          role_id: run.role_id,
          status: :running,
          started_at: DateTime.utc_now()
        })

      %{other: other}
    end

    test "waits in line, reads as waiting, and says which resource it is short of", %{run: run, other: other} do
      Repo.insert!(%OsProcess{
        run_id: other.id,
        task_id: other.task_id,
        stream_path: "/dev/null",
        status: :running,
        started_at: DateTime.utc_now(),
        reserved_cpus: 4,
        reserved_memory_gb: 2
      })

      reject(Tools, :spawn_os_process, 3)

      assert {:ok, %OsProcess{status: :waiting_for_resources, reserved_cpus: 1, reserved_memory_gb: 2, os_pid: nil}} =
               Tools.start_os_process(run, ["2"])

      assert :waiting = run.id |> then(&Repo.get!(Run, &1)) |> Run.state()

      assert [
               "[rail] Turn 1 needs 1 CPU and 2 GB, and every CPU on this machine is reserved. " <>
                 "It is 1st in line and starts on its own as soon as enough is free."
             ] = run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
    end

    test "names memory when memory is what it lacks, and its place behind the runs ahead", %{run: run, other: other} do
      Repo.insert!(%OsProcess{
        run_id: other.id,
        task_id: other.task_id,
        stream_path: "/dev/null",
        status: :running,
        started_at: DateTime.utc_now(),
        reserved_cpus: 1,
        reserved_memory_gb: 7
      })

      Repo.insert!(%OsProcess{
        run_id: other.id,
        task_id: other.task_id,
        stream_path: "/dev/null",
        status: :waiting_for_resources,
        started_at: DateTime.utc_now(),
        queued_at: DateTime.shift(DateTime.utc_now(), minute: -1),
        reserved_cpus: 1,
        reserved_memory_gb: 4,
        launch: "{}"
      })

      reject(Tools, :spawn_os_process, 3)

      assert {:ok, %OsProcess{status: :waiting_for_resources}} = Tools.start_os_process(run, ["2"])

      assert [
               "[rail] Turn 1 needs 1 CPU and 2 GB, and only 1 GB of this machine's memory is free. " <>
                 "It is 2nd in line and starts on its own as soon as enough is free."
             ] = run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
    end

    # Strictly oldest first: a run that would fit still waits behind one that does not.
    test "waits behind an older run even when it would fit", %{run: run, other: other} do
      Repo.insert!(%OsProcess{
        run_id: other.id,
        task_id: other.task_id,
        stream_path: "/dev/null",
        status: :running,
        started_at: DateTime.utc_now(),
        reserved_cpus: 2,
        reserved_memory_gb: 2
      })

      Repo.insert!(%OsProcess{
        run_id: other.id,
        task_id: other.task_id,
        stream_path: "/dev/null",
        status: :waiting_for_resources,
        started_at: DateTime.utc_now(),
        queued_at: DateTime.shift(DateTime.utc_now(), minute: -1),
        reserved_cpus: 3,
        reserved_memory_gb: 2,
        launch: "{}"
      })

      reject(Tools, :spawn_os_process, 3)

      assert {:ok, %OsProcess{status: :waiting_for_resources}} = Tools.start_os_process(run, ["2"])

      assert [
               "[rail] Turn 1 needs 1 CPU and 2 GB, and the runs ahead of it in line get what is free first. " <>
                 "It is 2nd in line and starts on its own as soon as enough is free."
             ] = run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
    end

    # Possible only when headroom was raised after its role was saved.
    test "a run at the front that could never fit is failed rather than holding the line", %{run: run, other: other} do
      Repo.insert!(%OsProcess{
        run_id: other.id,
        task_id: other.task_id,
        stream_path: "/dev/null",
        status: :waiting_for_resources,
        started_at: DateTime.utc_now(),
        queued_at: DateTime.shift(DateTime.utc_now(), minute: -1),
        reserved_cpus: 16,
        reserved_memory_gb: 2,
        launch: "{}"
      })

      expect(Tools, :spawn_os_process, fn _executable, _args, _opts -> {:ok, nil, 4245} end)
      expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

      assert {:ok, %OsProcess{status: :running}} = Tools.start_os_process(run, ["2"])

      assert {:ok,
              %Run{
                status: :finished,
                error:
                  "It needs 16 CPUs and 2 GB, and this machine has 4 CPUs and 8 GB to reserve, so it could never start."
              }} = Pipeline.get_run(other.id)
    end

    test "names both resources when it is short of both", %{run: run, other: other, scope: scope} do
      {:ok, role} = Roles.get_role(id: run.role_id)
      {:ok, _role} = Roles.update_role(scope, role, %{reserved_cpus: 3, reserved_memory_gb: 4})

      Repo.insert!(%OsProcess{
        run_id: other.id,
        task_id: other.task_id,
        stream_path: "/dev/null",
        status: :running,
        started_at: DateTime.utc_now(),
        reserved_cpus: 2,
        reserved_memory_gb: 8
      })

      reject(Tools, :spawn_os_process, 3)

      assert {:ok, %OsProcess{status: :waiting_for_resources}} = Tools.start_os_process(run, ["2"])

      assert [
               "[rail] Turn 1 needs 3 CPUs and 4 GB, and only 2 CPUs on this machine are free and " <>
                 "all of this machine's memory is reserved. It is 1st in line and starts on its own as soon as enough is free."
             ] = run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
    end

    test "a run ahead in line whose sandbox cannot start is failed with why, and the line moves on", %{
      run: run,
      other: other
    } do
      launch =
        Jason.encode!(%{
          "executable" => "/bin/true",
          "args" => [],
          "env" => %{},
          "cwd" => "/nonexistent/worktree",
          "stdout_path" => "/dev/null",
          "stderr_path" => "/dev/null"
        })

      Repo.insert!(%OsProcess{
        run_id: other.id,
        task_id: other.task_id,
        stream_path: "/dev/null",
        status: :waiting_for_resources,
        started_at: DateTime.utc_now(),
        queued_at: DateTime.shift(DateTime.utc_now(), minute: -1),
        reserved_cpus: 1,
        reserved_memory_gb: 2,
        launch: launch
      })

      expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

      assert {:ok, %OsProcess{status: :running} = os_process} = Tools.start_os_process(run, ["2"])

      assert {:ok, %Run{status: :finished, error: ~s|Could not start its sandbox: {:bad_cwd, "/nonexistent/worktree"}|}} =
               Pipeline.get_run(other.id)

      Tools.terminate_os_process(os_process.os_pid, grace_period: 100)
    end

    # What raising the headroom in prod does to a role saved before it.
    test "a turn the machine can no longer ever hold fails its run, rather than leaving it running", %{
      run: run,
      scope: scope
    } do
      {:ok, role} = Roles.get_role(id: run.role_id)
      {:ok, _role} = Roles.update_role(scope, role, %{reserved_cpus: 3})
      stub(Rail, :local_cpus, fn -> 2 end)
      Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run.id}")
      reject(Tools, :spawn_os_process, 3)

      error = "It needs 3 CPUs and 2 GB, and this machine has 2 CPUs and 8 GB to reserve, so it could never start."

      assert {:error, {:spawn_failed, _reason, %Run{status: :finished, error: ^error} = failed}} =
               Tools.start_os_process(run, ["2"])

      assert Run.state(failed) == :failed
      assert_receive {:run_changed, _run_id}
    end
  end

  describe "across accounts" do
    # Each test sets up the accounts it ranks, so the one from the file's setup is gone.
    setup %{backend: backend} do
      Repo.delete!(backend)
      stub(Tools, :spawn_os_process, fn _executable, _args, _opts -> {:ok, nil, 4242} end)
      stub(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

      # `hours` from now, so a window's reset reads the way a probe stores it.
      %{
        at: fn hours ->
          DateTime.utc_now() |> DateTime.shift(second: round(hours * 3600)) |> DateTime.truncate(:second)
        end
      }
    end

    test "a new turn goes to the account whose weekly usage resets soonest, and is stamped with it", %{
      at: at,
      model: model,
      run: run
    } do
      later = ready_backend(model, [{"Session", 90.0, at.(2)}, {"Weekly", 60.0, at.(120)}], %{label: "later"})
      %{id: soon_id} = ready_backend(model, [{"Session", 90.0, at.(2)}, {"Weekly", 30.0, at.(6)}], %{label: "soon"})

      assert {:ok, %OsProcess{backend_id: ^soon_id, status: :running}} = Tools.start_os_process(run, ["2"])
      refute later.id == soon_id
    end

    test "an account nearly out of its 5-hour window gets no new turn while another has room in both", %{
      at: at,
      model: model,
      run: run
    } do
      _tight = ready_backend(model, [{"Session", 10.0, at.(4)}, {"Weekly", 95.0, at.(100)}])
      %{id: roomy_id} = ready_backend(model, [{"Session", 70.0, at.(3)}, {"Weekly", 50.0, at.(72)}])

      assert {:ok, %OsProcess{backend_id: ^roomy_id}} = Tools.start_os_process(run, ["2"])
    end

    test "four turns started together on two identical accounts split two and two", %{
      at: at,
      model: model,
      run: run
    } do
      windows = [{"Session", 80.0, at.(3)}, {"Weekly", 80.0, at.(48)}]
      %{id: first_id} = ready_backend(model, windows)
      %{id: second_id} = ready_backend(model, windows)

      runs =
        for _turn <- 1..3 do
          {:ok, other} =
            Pipeline.create_run(%{
              task_id: run.task_id,
              role_id: run.role_id,
              status: :starting,
              started_at: DateTime.utc_now()
            })

          other
        end

      placed =
        [run | runs]
        |> Elixir.Task.async_stream(&Tools.start_os_process(&1, ["2"]), max_concurrency: 4)
        |> Enum.map(fn {:ok, {:ok, %OsProcess{backend_id: backend_id}}} -> backend_id end)

      assert %{^first_id => 2, ^second_id => 2} = Enum.frequencies(placed)
    end

    test "an account with a window used up is skipped, and picked again once that window's reset has passed", %{
      at: at,
      model: model,
      run: run
    } do
      used_up = ready_backend(model, [{"Weekly", 0.0, at.(10)}])
      %{id: other_id} = ready_backend(model, [{"Weekly", 20.0, at.(100)}])

      assert {:ok, %OsProcess{backend_id: ^other_id}} = Tools.start_os_process(run, ["2"])

      %{id: used_up_id} =
        used_up
        |> Backend.usage_changeset(%{
          name: :claude,
          status: :ready,
          usage: [
            %{
              name: "Weekly",
              details: %{
                "windows" => [
                  %{"label" => "Weekly", "remaining_percent" => 0.0, "resets_at" => DateTime.to_iso8601(at.(-1))}
                ]
              }
            }
          ]
        })
        |> Repo.update!()

      {:ok, again} =
        Pipeline.create_run(%{
          task_id: run.task_id,
          role_id: run.role_id,
          status: :starting,
          started_at: DateTime.utc_now()
        })

      assert {:ok, %OsProcess{backend_id: ^used_up_id}} = Tools.start_os_process(again, ["2"])
    end

    test "signed-out and unavailable accounts are never picked, however much they have left", %{
      at: at,
      model: model,
      run: run
    } do
      _signed_out = ready_backend(model, [], %{status: :signed_out})
      _unavailable = ready_backend(model, [], %{status: :unavailable})
      %{id: ready_id} = ready_backend(model, [{"Weekly", 5.0, at.(150)}])

      assert {:ok, %OsProcess{backend_id: ^ready_id}} = Tools.start_os_process(run, ["2"])
    end

    test "with every account used up the turn waits for usage, holding nothing, until the earliest reset", %{
      at: at,
      model: model,
      run: run
    } do
      soonest = at.(2)
      _weekly = ready_backend(model, [{"Weekly", 0.0, at.(30)}])
      _session = ready_backend(model, [{"Session", 0.0, soonest}])
      _signed_out = ready_backend(model, [], %{status: :signed_out})
      reject(Tools, :spawn_os_process, 3)

      assert {:ok,
              %OsProcess{
                id: os_process_id,
                status: :waiting_for_usage,
                backend_id: nil,
                reserved_cpus: nil,
                os_pid: nil,
                run: %Run{status: :waiting_for_usage}
              }} = Tools.start_os_process(run, ["2"])

      assert %Run{status: :waiting_for_usage} = waiting = Repo.get!(Run, run.id)
      assert Run.state(waiting) == :waiting
      assert [line] = run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
      assert line =~ "Every signed-in account offering #{model} has used up its usage"
      assert line =~ Calendar.strftime(soonest, "%-I:%M %p UTC on %b %-d")

      assert_enqueued(worker: StartAfterUsageReset, args: %{os_process_id: os_process_id}, scheduled_at: soonest)
      assert %{"argv" => ["2"], "token" => "" <> _token} = OsProcess.launch_spec(Repo.get!(OsProcess, os_process_id))
    end

    test "a resumed conversation stays on its account, and waits for that account's reset rather than moving", %{
      at: at,
      model: model,
      run: run
    } do
      %{id: home_id} = home = ready_backend(model, [{"Weekly", 90.0, at.(10)}], %{label: "home"})
      _elsewhere = ready_backend(model, [{"Weekly", 10.0, at.(150)}], %{label: "elsewhere"})

      assert {:ok, %OsProcess{id: first_id, backend_id: ^home_id}} = Tools.start_os_process(run, ["2"])
      OsProcess |> Repo.get!(first_id) |> OsProcess.changeset(%{status: :finished}) |> Repo.update!()
      {:ok, run} = Pipeline.update_run(Repo.get!(Run, run.id), %{conversation_id: "sess-home", status: :finished})

      # The other account now stands far higher, and the conversation still goes home.
      _higher = ready_backend(model, [], %{label: "fresh"})
      reset = at.(5)

      home
      |> Backend.usage_changeset(%{
        name: :claude,
        status: :ready,
        usage: [
          %{
            name: "Weekly",
            details: %{
              "windows" => [%{"label" => "Weekly", "remaining_percent" => 1.0, "resets_at" => DateTime.to_iso8601(reset)}]
            }
          }
        ]
      })
      |> Repo.update!()

      assert {:ok, %OsProcess{id: second_id, backend_id: ^home_id, status: :running}} = Tools.start_os_process(run, ["2"])
      OsProcess |> Repo.get!(second_id) |> OsProcess.changeset(%{status: :finished}) |> Repo.update!()

      Backend
      |> Repo.get!(home_id)
      |> Backend.usage_changeset(%{
        name: :claude,
        status: :ready,
        usage: [
          %{
            name: "Weekly",
            details: %{
              "windows" => [%{"label" => "Weekly", "remaining_percent" => 0.0, "resets_at" => DateTime.to_iso8601(reset)}]
            }
          }
        ]
      })
      |> Repo.update!()

      assert {:ok, %OsProcess{id: waiting_id, status: :waiting_for_usage, backend_id: ^home_id}} =
               Tools.start_os_process(run, ["2"])

      assert_enqueued(worker: StartAfterUsageReset, args: %{os_process_id: waiting_id}, scheduled_at: reset)

      assert run |> Pipeline.list_run_events() |> List.last() |> Map.fetch!(:line) =~
               "This conversation lives on Claude Code · home"
    end

    test "a resumed conversation whose account is signed out fails, naming that account", %{model: model, run: run} do
      home = ready_backend(model, [], %{label: "home"})
      assert {:ok, %OsProcess{id: first_id}} = Tools.start_os_process(run, ["2"])
      OsProcess |> Repo.get!(first_id) |> OsProcess.changeset(%{status: :finished}) |> Repo.update!()
      {:ok, run} = Pipeline.update_run(Repo.get!(Run, run.id), %{conversation_id: "sess-home", status: :finished})
      home |> Backend.usage_changeset(%{name: :claude, status: :signed_out}) |> Repo.update!()
      _other = ready_backend(model)

      assert {:error,
              {:spawn_failed, "This conversation lives on Claude Code · home, which is not signed in." <> _how, %Run{}}} =
               Tools.start_os_process(run, ["2"])

      assert %Run{error: "This conversation lives on Claude Code · home" <> _rest} = Repo.get!(Run, run.id)
    end

    test "with no signed-in account offering the model the run fails at once, naming it", %{
      model: model,
      role: role,
      run: run
    } do
      _signed_out = ready_backend(model, [], %{status: :signed_out})

      error =
        "No signed-in account offers #{model}. Sign one in on Settings › Backends, or pick another model for #{role.name}."

      assert {:error, {:spawn_failed, ^error, %Run{error: ^error}}} = Tools.start_os_process(run, ["2"])
      assert %Run{error: ^error, status: :finished} = settled = Repo.get!(Run, run.id)
      assert Run.state(settled) == :failed

      assert [%OsProcess{status: :finished, ended_reason: :failed_to_start}] =
               Repo.all(from p in OsProcess, where: p.run_id == ^run.id)
    end
  end
end
