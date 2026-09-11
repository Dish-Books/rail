defmodule Rail.Runs.FollowerTest do
  use Rail.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Domain.TaskUsage
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task, as: PipelineTask
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Follower
  alias Rail.Runs.FollowerSupervisor
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent
  alias Rail.Tools
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Follower Workspace",
        external_id: "lin_ws_follower",
        token: "lin_api_token_follower",
        webhook_secret: "whsec_follower"
      })

    tmp_dir = Path.join(System.tmp_dir!(), "follower_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    role_run =
      %RoleRun{}
      |> RoleRun.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    stream_path = Path.join(tmp_dir, "test.ndjson")
    File.write!(stream_path, "")
    File.write!("#{stream_path}.err", "")

    run =
      %Run{}
      |> Run.changeset(%{
        role_run_id: role_run.id,
        task_id: role_run.task_id,
        kind: :stage,
        stream_path: stream_path,
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    on_exit(fn ->
      File.rm_rf(tmp_dir)
    end)

    %{workspace: workspace, role_run: role_run, run: run, stream_path: stream_path, tmp_dir: tmp_dir}
  end

  test "tail polling, partial-line hold, and event parsing", %{
    role_run: role_run,
    run: run,
    stream_path: stream_path
  } do
    # Spawn a sleeping process to act as live child
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["10"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(
        run: run,
        role_run: role_run,
        stream_path: stream_path,
        os_pid: pid,
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
    role_run: role_run,
    run: run,
    stream_path: stream_path
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{role_run.id}")

    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["10"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(
        run: run,
        role_run: role_run,
        stream_path: stream_path,
        os_pid: pid,
        tail_interval_ms: 20,
        batch_interval_ms: 50
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    line1 = ~s({"type":"system","subtype":"init","session_id":"sess-batch-1"})
    line2 = ~s({"type":"assistant","message":{"content":[{"type":"text","text":"step 1"}]}})
    File.write!(stream_path, "#{line1}\n#{line2}\n")

    # PubSub broadcast should arrive on batch_tick
    assert_receive {:run_events, role_run_id, events}, 1_000
    assert role_run_id == role_run.id
    assert length(events) == 2

    # Check database persistence
    saved_events = Runs.list_run_events(role_run.id)
    assert length(saved_events) == 2
    assert Enum.at(saved_events, 0).seq == 1
    assert Enum.at(saved_events, 0).line == line1
    assert Enum.at(saved_events, 1).seq == 2
    assert Enum.at(saved_events, 1).line == line2

    FollowerSupervisor.stop_follower(follower_pid)
    Tools.terminate_os_process(pid, grace_period: 50)
  end

  test "child exit drains stderr, marks run finished, computes outcome and broadcasts", %{
    role_run: role_run,
    run: run,
    stream_path: stream_path
  } do
    test_pid = self()
    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{role_run.id}")

    # Process that exits after 100ms
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["0.1"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    line =
      ~s({"type":"result","subtype":"success","session_id":"sess-exit-1","usage":{"input_tokens":50,"output_tokens":25}})

    File.write!(stream_path, "#{line}\n")
    File.write!("#{stream_path}.err", "warning: minor deprecation\n")

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(
        run: run,
        role_run: role_run,
        stream_path: stream_path,
        os_pid: pid,
        tail_interval_ms: 20,
        batch_interval_ms: 50,
        on_finished: fn finished_run, outcome ->
          send(test_pid, {:callback_finished, finished_run, outcome})
        end
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    follower_ref = Process.monitor(follower_pid)

    # Wait for process exit and follower settlement
    assert_receive {:callback_finished, finished_run, outcome}, 2_000
    assert finished_run.status == :finished
    assert outcome.conversation_id == "sess-exit-1"
    assert %TaskUsage{input_tokens: 50, output_tokens: 25} = outcome.usage
    assert outcome.error =~ "warning: minor deprecation"

    assert_receive {:run_finished, _run, _outcome}, 500

    # Verify role_run row in DB
    reloaded_role_run = Runs.get_role_run!(role_run.id)
    assert reloaded_role_run.status == :finished
    assert reloaded_role_run.conversation_id == "sess-exit-1"
    assert reloaded_role_run.usage.input_tokens == 50

    # Follower GenServer should have stopped normally
    assert_receive {:DOWN, ^follower_ref, :process, ^follower_pid, :normal}, 2_000
    refute Process.alive?(follower_pid)
  end

  test "stop_run/2 terminates live process and settles run", %{
    role_run: role_run,
    run: run,
    stream_path: stream_path
  } do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["30"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    {:ok, _follower_pid} =
      FollowerSupervisor.start_follower(
        run: run,
        role_run: role_run,
        stream_path: stream_path,
        os_pid: pid,
        tail_interval_ms: 30
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), _follower_pid)

    assert Tools.os_process_alive?(pid)

    {:ok, stopped_run} = Runs.stop_run(run.id, grace_period: 100)
    assert stopped_run.status == :finished
    refute Tools.os_process_alive?(pid)
  end

  test "lenient UTF-8 handles invalid byte sequences gracefully", %{
    role_run: role_run,
    run: run,
    stream_path: stream_path
  } do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["5"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(
        run: run,
        role_run: role_run,
        stream_path: stream_path,
        os_pid: pid,
        tail_interval_ms: 20
      )

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

  test "skip_log_lines skips already recorded lines from being re-inserted", %{
    role_run: role_run,
    run: run,
    stream_path: stream_path
  } do
    # Seed 1 event in database
    Repo.insert!(%RunEvent{role_run_id: role_run.id, seq: 1, line: "already saved line"})

    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["5"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    line1 = ~s({"type":"system","session_id":"sess-replay-1"})
    line2 = ~s({"type":"assistant","message":{"content":[{"type":"text","text":"new line"}]}})
    File.write!(stream_path, "#{line1}\n#{line2}\n")

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(
        run: run,
        role_run: role_run,
        stream_path: stream_path,
        os_pid: pid,
        skip_log_lines: 1,
        tail_interval_ms: 20,
        batch_interval_ms: 40
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    # Wait for the follower to flush its batch.
    events =
      Enum.reduce_while(1..100, [], fn _i, _acc ->
        case Runs.list_run_events(role_run.id) do
          [_first, _second] = events -> {:halt, events}
          _other -> Process.sleep(10) && {:cont, []}
        end
      end)

    # Total events: 1 pre-existing + 1 new (line1 skipped)
    assert length(events) == 2
    assert Enum.at(events, 0).line == "already saved line"
    assert Enum.at(events, 1).line == line2

    FollowerSupervisor.stop_follower(follower_pid)
    Tools.terminate_os_process(pid, grace_period: 50)
  end

  test "custom name, get_state call, and ignored info messages", %{
    run: run,
    role_run: role_run,
    stream_path: stream_path
  } do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["5"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    custom_name = :custom_follower_test_proc

    {:ok, follower_pid} =
      Follower.start_link(
        run: run,
        role_run: role_run,
        stream_path: stream_path,
        os_pid: pid,
        name: custom_name,
        tail_interval_ms: 50_000
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    state = GenServer.call(follower_pid, :get_state)
    assert state.run_id == run.id

    dummy_pid = spawn(fn -> :ok end)
    send(follower_pid, {:EXIT, dummy_pid, :normal})
    send(follower_pid, :unknown_message)
    Process.sleep(20)
    assert Process.alive?(follower_pid)

    FollowerSupervisor.stop_follower(follower_pid)
    Tools.terminate_os_process(pid, grace_period: 50)
  end

  test "stop_run/2 accepts %Run{} struct and role_run_id string", %{
    run: run,
    role_run: role_run,
    stream_path: stream_path
  } do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["10"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    {:ok, _follower_pid} =
      FollowerSupervisor.start_follower(
        run: run,
        role_run: role_run,
        stream_path: stream_path,
        os_pid: pid,
        tail_interval_ms: 30
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), _follower_pid)

    # Stop via role_run_id
    {:ok, stopped} = Follower.stop_run(role_run.id)
    assert stopped.status == :finished
    refute Tools.os_process_alive?(pid)

    # Stop via %Run{} struct (when follower is not running, falls back)
    {:ok, stopped2} = Follower.stop_run(stopped)
    assert stopped2.status == :finished
  end

  test "child exit handles clean success without errors and passes exit_code from port", %{
    tmp_dir: tmp_dir
  } do
    role_run =
      %RoleRun{}
      |> RoleRun.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    stream = Path.join(tmp_dir, "clean_success.ndjson")
    line = ~s({"type":"result","subtype":"success","is_error":false,"session_id":"sess-clean"}\n)
    File.write!(stream, line)
    File.write!("#{stream}.err", "")

    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, :exit_status, args: ["0.05"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    run =
      %Run{}
      |> Run.changeset(%{
        role_run_id: role_run.id,
        task_id: role_run.task_id,
        kind: :stage,
        stream_path: stream,
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    test_pid = self()

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(
        run: run,
        role_run: role_run,
        stream_path: stream,
        os_pid: pid,
        port: port,
        tail_interval_ms: 10,
        batch_interval_ms: 20,
        on_finished: fn r, outcome -> send(test_pid, {:clean_finished, r, outcome}) end
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    follower_ref = Process.monitor(follower_pid)
    Process.unlink(port)

    assert_receive {:clean_finished, finished_run, outcome}, 1_000
    assert finished_run.status == :finished
    assert outcome.exit_code == 0
    assert is_nil(outcome.error)
    assert_receive {:DOWN, ^follower_ref, :process, ^follower_pid, :normal}, 2_000
    refute Process.alive?(follower_pid)
  end

  test "child exit handles both result_error only and result_error with stderr", %{
    tmp_dir: tmp_dir
  } do
    test_pid = self()

    # Part 1: result_error only (empty stderr)
    role_run1 =
      %RoleRun{}
      |> RoleRun.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    stream1 = Path.join(tmp_dir, "err_only.ndjson")
    line1 = ~s({"type":"result","subtype":"error","is_error":true,"session_id":"sess-err1"}\n)
    File.write!(stream1, line1)
    File.write!("#{stream1}.err", "")

    port1 = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["0.05"]])
    {:os_pid, pid1} = Port.info(port1, :os_pid)

    run1 =
      %Run{}
      |> Run.changeset(%{
        role_run_id: role_run1.id,
        task_id: role_run1.task_id,
        kind: :stage,
        stream_path: stream1,
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _follower_pid} =
      FollowerSupervisor.start_follower(
        run: run1,
        role_run: role_run1,
        stream_path: stream1,
        os_pid: pid1,
        tail_interval_ms: 10,
        on_finished: fn r, outcome -> send(test_pid, {:err_only_finished, r, outcome}) end
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), _follower_pid)

    Process.unlink(port1)

    assert_receive {:err_only_finished, _r1, outcome1}, 1_000
    assert outcome1.error == "claude reported error"

    # Part 2: both result_error and stderr
    role_run2 =
      %RoleRun{}
      |> RoleRun.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    stream2 = Path.join(tmp_dir, "err_both.ndjson")
    line2 = ~s({"type":"result","subtype":"error","is_error":true,"session_id":"sess-both"}\n)
    File.write!(stream2, line2)
    File.write!("#{stream2}.err", "stderr text here\n")

    port2 = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["0.05"]])
    {:os_pid, pid2} = Port.info(port2, :os_pid)

    run2 =
      %Run{}
      |> Run.changeset(%{
        role_run_id: role_run2.id,
        task_id: role_run2.task_id,
        kind: :stage,
        stream_path: stream2,
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _follower_pid} =
      FollowerSupervisor.start_follower(
        run: run2,
        role_run: role_run2,
        stream_path: stream2,
        os_pid: pid2,
        tail_interval_ms: 10,
        on_finished: fn r, outcome -> send(test_pid, {:both_finished, r, outcome}) end
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), _follower_pid)

    Process.unlink(port2)

    assert_receive {:both_finished, _r, outcome2}, 1_000
    assert outcome2.error =~ "claude reported error"
    assert outcome2.error =~ "stderr text here"
  end

  test "records exit_status from port message and sets exit_code on clean exit", %{
    tmp_dir: tmp_dir
  } do
    test_pid = self()

    role_run =
      %RoleRun{}
      |> RoleRun.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    stream = Path.join(tmp_dir, "port_exit.ndjson")
    line = ~s({"type":"result","subtype":"success","session_id":"sess-port-exit"}\n)
    File.write!(stream, line)
    File.write!("#{stream}.err", "")

    run =
      %Run{}
      |> Run.changeset(%{
        role_run_id: role_run.id,
        task_id: role_run.task_id,
        kind: :stage,
        stream_path: stream,
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(
        run: run,
        role_run: role_run,
        stream_path: stream,
        os_pid: 999_999,
        tail_interval_ms: 20,
        on_finished: fn r, outcome -> send(test_pid, {:port_exit_finished, r, outcome}) end
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    send(follower_pid, {nil, {:exit_status, 0}})

    assert_receive {:port_exit_finished, _r, outcome}, 1_000
    assert outcome.exit_code == 0
    assert is_nil(outcome.error)
  end

  test "pump_stream/4 with final: true flushes partial line, drain_err_file/1 handles errors, decode_utf8_lenient/1 handles incomplete bytes",
       %{
         tmp_dir: tmp_dir
       } do
    stream = Path.join(tmp_dir, "pump_final.ndjson")
    File.write!(stream, "complete line\n")

    size = File.stat!(stream).size
    {lines, offset, partial} = Follower.pump_stream(stream, size, "unflushed_partial", final: true)
    assert lines == ["unflushed_partial"]
    assert offset == size
    assert partial == ""

    # drain_err_file on a directory returns [] (read error)
    assert Follower.drain_err_file(tmp_dir) == []

    # pump_stream when file does not exist
    assert {[], 0, "partial"} = Follower.pump_stream("/tmp/nonexistent_file_xyz", 0, "partial")

    # decode_utf8_lenient with incomplete multibyte sequence
    incomplete = <<224, 160>>
    decoded = Follower.decode_utf8_lenient(incomplete)
    assert decoded =~ "\uFFFD"
  end

  test "detects question in stream and registers it to block task", %{
    tmp_dir: tmp_dir,
    workspace: workspace
  } do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        linear_workspace_id: workspace.id,
        name: "Follower Project 12502",
        github_repo: "org/follower-12502",
        github_installation_id: 12_502,
        linear_team_id: "team_follower_12502",
        linear_team_key: "P12502",
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
        name: "Role 12503",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 12503.",
        stage: :engineer
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_follower_12505",
      "identifier" => "TSK-12505",
      "title" => "Task 12505"
    })

    {:ok, issue_12505} = Issues.capture_issue(system_scope(), project, "Task 12505")

    {:ok, task} = Pipeline.create_task(issue_12505, :product)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    stream = Path.join(tmp_dir, "question_stream.ndjson")
    File.write!(stream, "")
    File.write!("#{stream}.err", "")

    run =
      Repo.insert!(%Run{
        role_run_id: role_run.id,
        task_id: task.id,
        kind: :stage,
        stream_path: stream,
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })

    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["10"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    {:ok, _follower_pid} =
      FollowerSupervisor.start_follower(
        run: run,
        role_run: role_run,
        stream_path: stream,
        os_pid: pid,
        tail_interval_ms: 20,
        batch_interval_ms: 30
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), _follower_pid)

    question_line =
      ~s({"type":"assistant","message":{"content":[{"type":"text","text":"[QUESTION: Which db to choose?] [OPTIONS: PG, MySQL]"}]}}\n)

    File.write!(stream, question_line)

    Process.sleep(100)

    reloaded_task = Repo.get!(PipelineTask, task.id)
    assert reloaded_task.stage_state == :blocked
    assert reloaded_task.question_id

    reloaded_rr = Repo.get!(RoleRun, role_run.id)
    assert reloaded_rr.status == :blocked_on_input

    Runs.stop_run(run.id, grace_period: 50)
  end

  test "chat child exit preserves role run status/output but updates conversation_id if new", %{
    tmp_dir: tmp_dir
  } do
    test_pid = self()
    task_id = UXID.generate!(prefix: "tsk")
    role_id = UXID.generate!(prefix: "rol")

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :running,
        started_at: DateTime.utc_now(),
        conversation_id: "sess-orig",
        output: "Preserved output"
      })

    stream = Path.join(tmp_dir, "chat_exit.ndjson")
    File.write!(stream, ~s({"type":"system","subtype":"init","session_id":"sess-updated"}\n))
    File.write!("#{stream}.err", "")

    run =
      Repo.insert!(%Run{
        role_run_id: role_run.id,
        task_id: task_id,
        kind: :chat,
        stream_path: stream,
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })

    port = Port.open({:spawn_executable, "/bin/echo"}, [:binary, args: ["done"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(
        run: run,
        role_run: role_run,
        stream_path: stream,
        os_pid: pid,
        tail_interval_ms: 20,
        batch_interval_ms: 30,
        on_finished: fn finished_run, outcome ->
          send(test_pid, {:chat_finished, finished_run, outcome})
        end
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    follower_ref = Process.monitor(follower_pid)

    assert_receive {:chat_finished, _run, _outcome}, 2_000
    assert_receive {:DOWN, ^follower_ref, :process, ^follower_pid, :normal}, 2_000

    reloaded_rr = Runs.get_role_run!(role_run.id)
    assert reloaded_rr.status == :running
    assert reloaded_rr.output == "Preserved output"
    assert reloaded_rr.conversation_id == "sess-updated"
  end

  test "chat child exit with same conversation_id leaves role run unchanged", %{
    tmp_dir: tmp_dir
  } do
    test_pid = self()
    task_id = UXID.generate!(prefix: "tsk")
    role_id = UXID.generate!(prefix: "rol")

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :running,
        started_at: DateTime.utc_now(),
        conversation_id: "sess-same",
        output: "Preserved"
      })

    stream = Path.join(tmp_dir, "chat_same.ndjson")
    File.write!(stream, ~s({"type":"init","session_id":"sess-same"}\n))
    File.write!("#{stream}.err", "")

    run =
      Repo.insert!(%Run{
        role_run_id: role_run.id,
        task_id: task_id,
        kind: :chat,
        stream_path: stream,
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })

    port = Port.open({:spawn_executable, "/bin/echo"}, [:binary, args: ["done"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(
        run: run,
        role_run: role_run,
        stream_path: stream,
        os_pid: pid,
        tail_interval_ms: 20,
        batch_interval_ms: 30,
        on_finished: fn finished_run, outcome ->
          send(test_pid, {:same_chat_finished, finished_run, outcome})
        end
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    follower_ref = Process.monitor(follower_pid)

    assert_receive {:same_chat_finished, _run, _outcome}, 2_000
    assert_receive {:DOWN, ^follower_ref, :process, ^follower_pid, :normal}, 2_000

    reloaded_rr = Runs.get_role_run!(role_run.id)
    assert reloaded_rr.conversation_id == "sess-same"
  end

  test "stage child exit without usage map updates role run with nil usage", %{
    tmp_dir: tmp_dir
  } do
    test_pid = self()
    task_id = UXID.generate!(prefix: "tsk")
    role_id = UXID.generate!(prefix: "rol")

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    stream = Path.join(tmp_dir, "stage_no_usage.ndjson")
    File.write!(stream, "plain non-json log line\n")
    File.write!("#{stream}.err", "")

    run =
      Repo.insert!(%Run{
        role_run_id: role_run.id,
        task_id: task_id,
        kind: :stage,
        stream_path: stream,
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })

    port = Port.open({:spawn_executable, "/bin/echo"}, [:binary, args: ["done"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(
        run: run,
        role_run: role_run,
        stream_path: stream,
        os_pid: pid,
        tail_interval_ms: 20,
        batch_interval_ms: 30,
        on_finished: fn finished_run, outcome ->
          send(test_pid, {:stage_no_usage_finished, finished_run, outcome})
        end
      )

    # The follower runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), follower_pid)

    follower_ref = Process.monitor(follower_pid)

    assert_receive {:stage_no_usage_finished, _run, _outcome}, 2_000
    assert_receive {:DOWN, ^follower_ref, :process, ^follower_pid, :normal}, 2_000

    reloaded_rr = Runs.get_role_run!(role_run.id)
    assert reloaded_rr.status == :finished
    assert %TaskUsage{input_tokens: 0} = reloaded_rr.usage
  end
end
