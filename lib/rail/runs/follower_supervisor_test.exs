defmodule Rail.Runs.FollowerSupervisorTest do
  use Rail.DataCase, async: true

  alias Rail.Backends.Schemas.Backend
  alias Rail.Runs
  alias Rail.Runs.FollowerSupervisor
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias Rail.Tools

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "supervisor_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    run =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    stream_path = Path.join(tmp_dir, "sup_test.ndjson")
    File.write!(stream_path, "")
    File.write!("#{stream_path}.err", "")

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
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

    %{backend: %Backend{name: :claude}, run: run, os_process: os_process, stream_path: stream_path}
  end

  test "starts and stops follower children under supervision", %{
    backend: backend,
    run: run,
    os_process: os_process,
    stream_path: stream_path
  } do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["10"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(
        os_process: os_process,
        backend: backend,
        run: run,
        stream_path: stream_path,
        os_pid: pid
      )

    assert is_pid(follower_pid)
    assert Process.alive?(follower_pid)

    # Lookup in registry
    assert Runs.get_follower_pid(os_process.id) == follower_pid

    # Stop child via supervisor
    assert FollowerSupervisor.stop_follower(follower_pid) == :ok
    refute Process.alive?(follower_pid)
    Process.sleep(10)
    assert Runs.get_follower_pid(os_process.id) == nil

    Tools.terminate_os_process(pid, grace_period: 50)
  end
end
