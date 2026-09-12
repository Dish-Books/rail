defmodule Rail.Runs.BootTest do
  use Rail.DataCase, async: true

  alias Rail.Runs
  alias Rail.Runs.Boot
  alias Rail.Runs.FollowerSupervisor
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias Rail.Tools

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "boot_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "adopts live child process, starts Follower and replays stream", %{tmp_dir: tmp_dir} do
    run =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now(),
        attempt_log_lines: 1
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
        kind: :stage,
        stream_path: stream_path,
        node: to_string(Node.self()),
        status: :running,
        os_pid: pid,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    results = Boot.adopt_live_os_processes(node: to_string(Node.self()))
    assert [{:adopted_live, %OsProcess{id: ^os_process_id}, follower_pid}] = results
    assert is_pid(follower_pid)
    assert Process.alive?(follower_pid)

    # Calling adopt again sees it is already followed
    repeat = Boot.adopt_live_os_processes(node: to_string(Node.self()))
    assert [{:already_following, _run, ^follower_pid}] = repeat

    FollowerSupervisor.stop_follower(follower_pid)
    Tools.terminate_os_process(pid, grace_period: 50)
  end

  test "settles dead child process as finished while unwatched", %{tmp_dir: tmp_dir} do
    run =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
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
        kind: :stage,
        stream_path: stream_path,
        node: to_string(Node.self()),
        status: :running,
        os_pid: dead_pid,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    results = Boot.adopt_live_os_processes(node: to_string(Node.self()))
    assert [{:adopted_dead, %OsProcess{status: :adopted_dead}}] = results

    # Run should be settled
    settled_run = Runs.get_run!(run.id)
    assert settled_run.status == :finished
    assert settled_run.exit_code == 0
    assert settled_run.conversation_id == "sess-dead-1"
    assert settled_run.usage.input_tokens == 150
  end

  test "settles dead child process with no result as failure with transient pattern", %{
    tmp_dir: tmp_dir
  } do
    run =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
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
        kind: :stage,
        stream_path: stream_path,
        node: to_string(Node.self()),
        status: :running,
        os_pid: 999_997,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    results = Boot.adopt_live_os_processes(node: to_string(Node.self()))
    assert [{:adopted_dead, %OsProcess{status: :adopted_dead}}] = results

    settled_run = Runs.get_run!(run.id)
    assert settled_run.status == :finished
    assert settled_run.exit_code == -1
    assert settled_run.error =~ "without reporting a result"
    # Verify failure pattern is recognized as transient by RunFailure
    assert Runs.transient?(settled_run.error)
  end

  test "starting run without PID times out and fails after 60s", %{tmp_dir: tmp_dir} do
    run =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
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
        kind: :stage,
        stream_path: stream_path,
        node: to_string(Node.self()),
        status: :starting,
        os_pid: nil,
        started_at: DateTime.shift(DateTime.utc_now(), second: -70)
      })
      |> Repo.insert!()

    results = Boot.adopt_live_os_processes(node: to_string(Node.self()), timeout_seconds: 60)
    assert [{:failed_starting, %OsProcess{status: :finished}}] = results

    settled_run = Runs.get_run!(run.id)
    assert settled_run.status == :finished
    assert settled_run.error =~ "Spawn timed out"
  end

  test "starting run within timeout is left alone", %{tmp_dir: tmp_dir} do
    run =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
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
        kind: :stage,
        stream_path: stream_path,
        node: to_string(Node.self()),
        status: :starting,
        os_pid: nil,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    results = Boot.adopt_live_os_processes(node: to_string(Node.self()), timeout_seconds: 60)
    assert [{:still_starting, %OsProcess{id: ^os_process_id}}] = results
  end

  test "ignores runs from different node or already finished", %{tmp_dir: tmp_dir} do
    run =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    stream_path = Path.join(tmp_dir, "foreign.ndjson")
    File.write!(stream_path, "")
    File.write!("#{stream_path}.err", "")

    # Foreign node run
    Repo.insert!(%OsProcess{
      run_id: run.id,
      task_id: run.task_id,
      kind: :stage,
      stream_path: stream_path,
      node: "other_node@remote_host",
      status: :running,
      os_pid: 999_990,
      started_at: DateTime.utc_now()
    })

    # Already finished run
    Repo.insert!(%OsProcess{
      run_id: run.id,
      task_id: run.task_id,
      kind: :stage,
      stream_path: stream_path,
      node: to_string(Node.self()),
      status: :finished,
      os_pid: 999_991,
      started_at: DateTime.utc_now()
    })

    results = Boot.adopt_live_os_processes(node: to_string(Node.self()))
    assert results == []
  end

  test "start_link/1 executes adoption as task" do
    {:ok, pid} = Boot.start_link(node: "nonexistent_node")
    assert is_pid(pid)
    # Task should finish quickly and exit normally
    Process.sleep(50)
    refute Process.alive?(pid)
  end

  test "run/1 executes when adopt_on_boot is enabled" do
    Application.put_env(:rail, :adopt_on_boot, true)
    on_exit(fn -> Application.put_env(:rail, :adopt_on_boot, false) end)

    assert Boot.reconcile(node: "nonexistent_node") == []
  end

  test "settles dead run with various error and stderr combinations", %{tmp_dir: tmp_dir} do
    test_pid = self()

    # Case 1: both result_error and stderr
    run1 =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
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
      kind: :stage,
      stream_path: stream1,
      node: to_string(Node.self()),
      status: :running,
      os_pid: 999_980,
      started_at: DateTime.utc_now()
    })

    Boot.adopt_live_os_processes(
      node: to_string(Node.self()),
      on_finished: fn os_process, outcome ->
        send(test_pid, {:custom_boot_finished, os_process, outcome})
      end
    )

    assert_receive {:custom_boot_finished, _run, outcome1}, 500
    assert outcome1.error =~ "claude reported error"
    assert outcome1.error =~ "stderr log output"

    # Case 2: result_error only (no stderr)
    run2 =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
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
      kind: :stage,
      stream_path: stream2,
      node: to_string(Node.self()),
      status: :running,
      os_pid: 999_981,
      started_at: DateTime.utc_now()
    })

    Boot.adopt_live_os_processes(node: to_string(Node.self()))
    r2 = Runs.get_run!(run2.id)
    assert r2.error == "claude reported error_max_turns"

    # Case 3: stderr only, saw_result was true
    run3 =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
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
      kind: :stage,
      stream_path: stream3,
      node: to_string(Node.self()),
      status: :running,
      os_pid: 999_982,
      started_at: DateTime.utc_now()
    })

    Boot.adopt_live_os_processes(node: to_string(Node.self()))
    r3 = Runs.get_run!(run3.id)
    assert r3.error == "only stderr output"

    # Case 4: stream path does not exist
    run4 =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    %OsProcess{id: run4_id} =
      Repo.insert!(%OsProcess{
        run_id: run4.id,
        task_id: run4.task_id,
        kind: :stage,
        stream_path: Path.join(tmp_dir, "nonexistent.ndjson"),
        node: to_string(Node.self()),
        status: :running,
        os_pid: 999_983,
        started_at: DateTime.utc_now()
      })

    assert [{:adopted_dead, %OsProcess{id: ^run4_id}}] = Boot.adopt_live_os_processes(node: to_string(Node.self()))
  end
end
