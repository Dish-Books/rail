defmodule Rail.Runs.FollowerSupervisorTest do
  use Rail.DataCase, async: true

  alias Rail.Runs
  alias Rail.Runs.FollowerSupervisor
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias Rail.Tools

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "supervisor_test_#{System.unique_integer([:positive])}")
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

    stream_path = Path.join(tmp_dir, "sup_test.ndjson")
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
        boot_id: Runs.boot_id(),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    on_exit(fn ->
      File.rm_rf(tmp_dir)
    end)

    %{role_run: role_run, run: run, stream_path: stream_path}
  end

  test "starts and stops follower children under supervision", %{
    role_run: role_run,
    run: run,
    stream_path: stream_path
  } do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["10"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(
        run: run,
        role_run: role_run,
        stream_path: stream_path,
        os_pid: pid
      )

    assert is_pid(follower_pid)
    assert Process.alive?(follower_pid)

    # Lookup in registry
    assert Runs.get_follower_pid(run.id) == follower_pid

    # Stop child via supervisor
    assert FollowerSupervisor.stop_follower(follower_pid) == :ok
    refute Process.alive?(follower_pid)
    Process.sleep(10)
    assert Runs.get_follower_pid(run.id) == nil

    Tools.terminate_os_process(pid, grace_period: 50)
  end
end
