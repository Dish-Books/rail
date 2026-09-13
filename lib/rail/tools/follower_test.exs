defmodule Rail.Tools.FollowerTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.QuestionQueue

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task, as: PipelineTask
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Follower
  alias Rail.Tools.FollowerSupervisor
  alias Rail.Tools.Schemas.OsProcess

  # The Follower watches a real OS process.
  @moduletag :real_spawn

  setup do
    {:ok, backend} =
      Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Follower Project",
        github_repo: "org/follower",
        github_installation_id: System.unique_integer([:positive]),
        linear_workspace: %{
          name: "Follower Workspace",
          external_id: "lin_ws_follower",
          token: "lin_api_token_follower",
          webhook_secret: "whsec_follower"
        },
        linear_team_id: "team_follower",
        linear_team_key: "FOL",
        default_branch: "main",
        clone_path: Path.join(System.tmp_dir!(), "follower_clone")
      })

    # The Follower reads the stream in its backend's format, and the backend comes
    # off the run's role.
    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        backend_id: backend.id,
        stage: :engineer,
        name: "follower role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the engineer."
      })

    tmp_dir = Path.join(System.tmp_dir!(), "follower_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    # A run always belongs to a real task: settling one reads the task off it.
    task =
      %PipelineTask{}
      |> PipelineTask.changeset(
        %{
          stage: :engineer,
          worktree_name: "follower-#{System.unique_integer([:positive])}",
          worktree_path: Path.join(tmp_dir, "worktree"),
          scratch_path: Path.join(tmp_dir, "scratch")
        },
        project.id
      )
      |> Repo.insert!()

    run =
      %Run{}
      |> Run.changeset(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()
      |> Repo.preload(role: :backend)

    stream_path = Path.join(tmp_dir, "test.ndjson")
    File.write!(stream_path, "")
    File.write!("#{stream_path}.err", "")

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: stream_path,
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    on_exit(fn ->
      File.rm_rf(tmp_dir)
    end)

    %{
      backend: backend,
      role: role,
      task: task,
      run: run,
      os_process: os_process,
      stream_path: stream_path,
      tmp_dir: tmp_dir
    }
  end

  test "tail polling, partial-line hold, and event parsing", %{
    run: run,
    os_process: os_process,
    stream_path: stream_path
  } do
    # Spawn a sleeping process to act as live child
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["10"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(%{os_process | os_pid: pid, run: run},
        tail_interval_ms: 30,
        batch_interval_ms: 50
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    # Write partial line
    File.write!(stream_path, ~s({"type":"system","sub))
    Process.sleep(50)

    state = :sys.get_state(follower_pid)
    assert state.partial_line == ~s({"type":"system","sub)
    assert state.event_state.conversation_id == nil

    # Complete the line and add another
    File.write!(
      stream_path,
      ~s(type":"init","session_id":"sess-claude-1"}\n{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}\n),
      [:append]
    )

    Process.sleep(80)

    updated_state = :sys.get_state(follower_pid)
    assert updated_state.partial_line == ""
    assert updated_state.event_state.conversation_id == "sess-claude-1"
    assert updated_state.event_state.assistant_text =~ "Done"

    # Stop process and follower
    FollowerSupervisor.stop_follower(follower_pid)
    Tools.terminate_os_process(pid, grace_period: 50)
  end

  test "250ms batching writes to run_events table and broadcasts on PubSub", %{
    run: run,
    os_process: os_process,
    stream_path: stream_path
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run.id}")

    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["10"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(%{os_process | os_pid: pid, run: run},
        tail_interval_ms: 20,
        batch_interval_ms: 50
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    line1 = ~s({"type":"system","subtype":"init","session_id":"sess-batch-1"})
    line2 = ~s({"type":"assistant","message":{"content":[{"type":"text","text":"step 1"}]}})
    File.write!(stream_path, "#{line1}\n#{line2}\n")

    # PubSub broadcast should arrive on batch_tick
    assert_receive {:run_events, run_id, events}, 1_000
    assert run_id == run.id
    assert length(events) == 2

    # Check database persistence
    saved_events = Pipeline.list_run_events(run)
    assert length(saved_events) == 2
    assert Enum.at(saved_events, 0).line == line1
    assert Enum.at(saved_events, 1).line == line2
    assert Enum.all?(saved_events, &(&1.os_process_id == os_process.id))

    FollowerSupervisor.stop_follower(follower_pid)
    Tools.terminate_os_process(pid, grace_period: 50)
  end

  test "child exit drains stderr, marks run finished, computes outcome and broadcasts", %{
    run: run,
    os_process: os_process,
    stream_path: stream_path
  } do
    # Process that exits after 100ms
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["0.1"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    line =
      ~s({"type":"result","subtype":"success","session_id":"sess-exit-1","usage":{"input_tokens":50,"output_tokens":25}})

    File.write!(stream_path, "#{line}\n")
    File.write!("#{stream_path}.err", "warning: minor deprecation\n")

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run.id}")

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(%{os_process | os_pid: pid, run: run},
        tail_interval_ms: 20,
        batch_interval_ms: 50
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    follower_ref = Process.monitor(follower_pid)

    # Wait for process exit and follower settlement
    assert_receive {:os_process_finished, finished_run, outcome}, 2_000
    assert finished_run.status == :finished
    assert outcome.conversation_id == "sess-exit-1"
    assert %Run.Usage{input_tokens: 50, output_tokens: 25} = outcome.usage
    assert outcome.error =~ "warning: minor deprecation"

    # Verify run row in DB
    {:ok, reloaded_run} = Pipeline.get_run(run.id)
    assert reloaded_run.status == :finished
    assert reloaded_run.conversation_id == "sess-exit-1"
    assert reloaded_run.usage.input_tokens == 50

    # Follower GenServer should have stopped normally
    assert_receive {:DOWN, ^follower_ref, :process, ^follower_pid, :normal}, 2_000
    refute Process.alive?(follower_pid)
  end

  test "stop_os_process/2 terminates live process and settles run", %{
    run: run,
    os_process: os_process
  } do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["30"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(%{os_process | os_pid: pid, run: run}, tail_interval_ms: 30)

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    assert Tools.os_process_alive?(pid)

    {:ok, stopped_run} = Tools.stop_os_process(os_process, grace_period: 100)
    assert stopped_run.status == :finished
    refute Tools.os_process_alive?(pid)
  end

  test "lenient UTF-8 handles invalid byte sequences gracefully", %{
    run: run,
    os_process: os_process,
    stream_path: stream_path
  } do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["5"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(%{os_process | os_pid: pid, run: run}, tail_interval_ms: 20)

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    invalid_utf8_line =
      <<(~s({"type":"assistant","message":{"content":[{"type":"text","text":"bad )), 255, " byte\"}]}}\n">>

    File.write!(stream_path, invalid_utf8_line)
    Process.sleep(50)

    state = :sys.get_state(follower_pid)
    assert state.event_state.assistant_text =~ "bad"
    assert state.event_state.assistant_text =~ "byte"

    FollowerSupervisor.stop_follower(follower_pid)
    Tools.terminate_os_process(pid, grace_period: 50)
  end

  test "ignores info messages it does not recognize", %{os_process: os_process, run: run} do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["5"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(%{os_process | os_pid: pid, run: run}, tail_interval_ms: 50_000)

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    dummy_pid = spawn(fn -> :ok end)
    send(follower_pid, {:EXIT, dummy_pid, :normal})
    send(follower_pid, :unknown_message)
    Process.sleep(20)
    assert Process.alive?(follower_pid)

    FollowerSupervisor.stop_follower(follower_pid)
    Tools.terminate_os_process(pid, grace_period: 50)
  end

  test "stop_os_process/2 falls back to terminating the row when no follower is registered", %{
    os_process: os_process,
    run: run
  } do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["10"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(%{os_process | os_pid: pid, run: run}, tail_interval_ms: 30)

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    {:ok, stopped} = Follower.stop_os_process(os_process)
    assert stopped.status == :finished
    refute Tools.os_process_alive?(pid)

    # The follower is gone now, so this second call takes the fallback path.
    {:ok, stopped2} = Follower.stop_os_process(stopped)
    assert stopped2.status == :finished
  end

  test "child exit handles clean success without errors and passes exit_code from port", %{
    role: role,
    tmp_dir: tmp_dir
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
      |> Repo.preload(role: :backend)

    stream = Path.join(tmp_dir, "clean_success.ndjson")
    line = ~s({"type":"result","subtype":"success","is_error":false,"session_id":"sess-clean"}\n)
    File.write!(stream, line)
    File.write!("#{stream}.err", "")

    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, :exit_status, args: ["0.05"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: stream,
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run.id}")

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(%{os_process | os_pid: pid, run: run},
        port: port,
        tail_interval_ms: 10,
        batch_interval_ms: 20
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    follower_ref = Process.monitor(follower_pid)
    Process.unlink(port)

    assert_receive {:os_process_finished, finished_run, outcome}, 1_000
    assert finished_run.status == :finished
    assert outcome.exit_code == 0
    assert is_nil(outcome.error)
    assert_receive {:DOWN, ^follower_ref, :process, ^follower_pid, :normal}, 2_000
    refute Process.alive?(follower_pid)
  end

  test "child exit handles both result_error only and result_error with stderr", %{
    role: role,
    tmp_dir: tmp_dir
  } do
    # Part 1: result_error only (empty stderr)
    run1 =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()
      |> Repo.preload(role: :backend)

    stream1 = Path.join(tmp_dir, "err_only.ndjson")
    line1 = ~s({"type":"result","subtype":"error","is_error":true,"session_id":"sess-err1"}\n)
    File.write!(stream1, line1)
    File.write!("#{stream1}.err", "")

    port1 = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["0.05"]])
    {:os_pid, pid1} = Port.info(port1, :os_pid)

    os_process1 =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run1.id,
        task_id: run1.task_id,
        stream_path: stream1,
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run1.id}")

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(%{os_process1 | os_pid: pid1, run: run1}, tail_interval_ms: 10)

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    Process.unlink(port1)

    assert_receive {:os_process_finished, _r1, outcome1}, 1_000
    assert outcome1.error == "claude reported error"

    # Part 2: both result_error and stderr
    run2 =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()
      |> Repo.preload(role: :backend)

    stream2 = Path.join(tmp_dir, "err_both.ndjson")
    line2 = ~s({"type":"result","subtype":"error","is_error":true,"session_id":"sess-both"}\n)
    File.write!(stream2, line2)
    File.write!("#{stream2}.err", "stderr text here\n")

    port2 = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["0.05"]])
    {:os_pid, pid2} = Port.info(port2, :os_pid)

    os_process2 =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run2.id,
        task_id: run2.task_id,
        stream_path: stream2,
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run2.id}")

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(%{os_process2 | os_pid: pid2, run: run2}, tail_interval_ms: 10)

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    Process.unlink(port2)

    assert_receive {:os_process_finished, _r, outcome2}, 1_000
    assert outcome2.error =~ "claude reported error"
    assert outcome2.error =~ "stderr text here"
  end

  test "records exit_status from port message and sets exit_code on clean exit", %{role: role, tmp_dir: tmp_dir} do
    run =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()
      |> Repo.preload(role: :backend)

    stream = Path.join(tmp_dir, "port_exit.ndjson")
    line = ~s({"type":"result","subtype":"success","session_id":"sess-port-exit"}\n)
    File.write!(stream, line)
    File.write!("#{stream}.err", "")

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: stream,
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run.id}")

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(%{os_process | os_pid: 999_999, run: run}, tail_interval_ms: 20)

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    send(follower_pid, {nil, {:exit_status, 0}})

    assert_receive {:os_process_finished, _r, outcome}, 1_000
    assert outcome.exit_code == 0
    assert is_nil(outcome.error)
  end

  test "detects question in stream and registers it to block task", %{
    backend: backend,
    tmp_dir: tmp_dir
  } do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        linear_workspace: %{
          name: "Follower Workspace",
          external_id: "lin_ws_follower_2",
          token: "lin_api_token_follower",
          webhook_secret: "whsec_follower"
        },
        name: "Follower Project 12502",
        github_repo: "org/follower-12502",
        github_installation_id: 12_502,
        linear_team_id: "team_follower_12502",
        linear_team_key: "P12502",
        default_branch: "main",
        clone_path: "/tmp/repos/follower-12502",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        backend_id: backend.id,
        name: "Role 12503",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 12503.",
        stage: :engineer
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_task_follower_12505",
              "identifier" => "TSK-12505",
              "title" => "Task 12505"
            }
          }
        }
      })
    end)

    {:ok, issue_12505} = Issues.create_issue(project, %{description: "Task 12505"})

    {:ok, task} = Pipeline.create_task(issue_12505, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :engineer
      })

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, role: :backend)

    Pipeline.append_run_events(run.id, nil, ["Completed task implementation successfully."])

    stream = Path.join(tmp_dir, "question_stream.ndjson")
    File.write!(stream, "")
    File.write!("#{stream}.err", "")

    os_process =
      Repo.insert!(%OsProcess{
        run_id: run.id,
        task_id: task.id,
        stream_path: stream,
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })

    # The agent ends its step by asking, so both questions are in the log the
    # process leaves behind rather than read off the stream as it runs.
    File.write!(
      stream,
      ~s({"type":"assistant","message":{"content":[{"type":"text","text":"[QUESTION: Which db to choose?] [OPTIONS: PG, MySQL]"}]}}\n) <>
        ~s({"type":"assistant","message":{"content":[{"type":"text","text":"[QUESTION: Ship behind a flag?]"}]}}\n)
    )

    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["0.1"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run.id}")

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(%{os_process | os_pid: pid, run: run},
        port: port,
        tail_interval_ms: 20,
        batch_interval_ms: 30
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    assert_receive {:os_process_finished, _os_process, _outcome}, 2_000

    # Both are filed, in the order asked, and the task parks on the first.
    assert Enum.map(pending_questions(task.id), & &1.prompt) == [
             "Which db to choose?",
             "Ship behind a flag?"
           ]

    assert Repo.reload!(run).status == :blocked_on_input

    assert Repo.get!(Run, run.id).status == :blocked_on_input
  end

  test "a run already holding a conversation keeps it, whatever a later child reports", %{
    role: role,
    tmp_dir: tmp_dir
  } do
    task_id = UXID.generate!(prefix: "tsk")

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task_id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now(),
        conversation_id: "sess-orig"
      })

    run = Repo.preload(run, role: :backend)

    Pipeline.append_run_events(run.id, nil, ["Completed task implementation successfully."])

    stream = Path.join(tmp_dir, "chat_exit.ndjson")
    File.write!(stream, ~s({"type":"system","subtype":"init","session_id":"sess-updated"}\n))
    File.write!("#{stream}.err", "")

    os_process =
      Repo.insert!(%OsProcess{
        run_id: run.id,
        task_id: task_id,
        stream_path: stream,
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })

    port = Port.open({:spawn_executable, "/bin/echo"}, [:binary, args: ["done"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run.id}")

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(%{os_process | os_pid: pid, run: run},
        tail_interval_ms: 20,
        batch_interval_ms: 30
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    follower_ref = Process.monitor(follower_pid)

    assert_receive {:os_process_finished, _run, _outcome}, 2_000
    assert_receive {:DOWN, ^follower_ref, :process, ^follower_pid, :normal}, 2_000

    {:ok, reloaded_rr} = Pipeline.get_run(run.id)
    assert reloaded_rr.conversation_id == "sess-orig"
  end

  test "chat child exit with same conversation_id leaves run unchanged", %{role: role, tmp_dir: tmp_dir} do
    task_id = UXID.generate!(prefix: "tsk")

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task_id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now(),
        conversation_id: "sess-same"
      })

    run = Repo.preload(run, role: :backend)

    Pipeline.append_run_events(run.id, nil, ["Completed task implementation successfully."])

    stream = Path.join(tmp_dir, "chat_same.ndjson")
    File.write!(stream, ~s({"type":"init","session_id":"sess-same"}\n))
    File.write!("#{stream}.err", "")

    os_process =
      Repo.insert!(%OsProcess{
        run_id: run.id,
        task_id: task_id,
        stream_path: stream,
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })

    port = Port.open({:spawn_executable, "/bin/echo"}, [:binary, args: ["done"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run.id}")

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(%{os_process | os_pid: pid, run: run},
        tail_interval_ms: 20,
        batch_interval_ms: 30
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    follower_ref = Process.monitor(follower_pid)

    assert_receive {:os_process_finished, _run, _outcome}, 2_000
    assert_receive {:DOWN, ^follower_ref, :process, ^follower_pid, :normal}, 2_000

    {:ok, reloaded_rr} = Pipeline.get_run(run.id)
    assert reloaded_rr.conversation_id == "sess-same"
  end

  test "stage child exit without usage map updates run with nil usage", %{
    role: role,
    task: %PipelineTask{id: task_id},
    tmp_dir: tmp_dir
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task_id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, role: :backend)

    Pipeline.append_run_events(run.id, nil, ["Completed task implementation successfully."])

    stream = Path.join(tmp_dir, "stage_no_usage.ndjson")
    File.write!(stream, "plain non-json log line\n")
    File.write!("#{stream}.err", "")

    os_process =
      Repo.insert!(%OsProcess{
        run_id: run.id,
        task_id: task_id,
        stream_path: stream,
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })

    port = Port.open({:spawn_executable, "/bin/echo"}, [:binary, args: ["done"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run.id}")

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(%{os_process | os_pid: pid, run: run},
        tail_interval_ms: 20,
        batch_interval_ms: 30
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    follower_ref = Process.monitor(follower_pid)

    assert_receive {:os_process_finished, _run, _outcome}, 2_000
    assert_receive {:DOWN, ^follower_ref, :process, ^follower_pid, :normal}, 2_000

    {:ok, reloaded_rr} = Pipeline.get_run(run.id)
    assert reloaded_rr.status == :finished
    assert %Run.Usage{input_tokens: 0} = reloaded_rr.usage
  end
end
