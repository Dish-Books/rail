defmodule Rail.Runs.FollowerSupervisorTest do
  use Rail.DataCase, async: true

  import Rail.Runs.Utils.GetFollowerPid

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
        stream_path: stream_path,
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    on_exit(fn ->
      File.rm_rf(tmp_dir)
    end)

    %{run: run, os_process: os_process, stream_path: stream_path}
  end

  test "starts and stops follower children under supervision", %{
    run: run,
    os_process: os_process
  } do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["10"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(%{os_process | os_pid: pid, run: run})

    assert is_pid(follower_pid)
    assert Process.alive?(follower_pid)

    # Lookup in registry
    assert get_follower_pid(os_process.id) == follower_pid

    # Stop child via supervisor
    assert FollowerSupervisor.stop_follower(follower_pid) == :ok
    refute Process.alive?(follower_pid)
    Process.sleep(10)
    assert get_follower_pid(os_process.id) == nil

    Tools.terminate_os_process(pid, grace_period: 50)
  end

  test "hands a spawned port to the follower and unlinks it from the caller", %{
    run: run,
    os_process: os_process,
    stream_path: stream_path
  } do
    {:ok, port, os_pid} = Tools.spawn_os_process("/bin/sleep", ["10"], stdout_path: stream_path)

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(%{os_process | os_pid: os_pid, run: run}, port: port)

    assert Port.info(port, :connected) == {:connected, follower_pid}
    {:links, links} = Process.info(self(), :links)
    refute port in links

    FollowerSupervisor.stop_follower(follower_pid)
    Tools.terminate_os_process(os_pid, grace_period: 50)
  end
end
