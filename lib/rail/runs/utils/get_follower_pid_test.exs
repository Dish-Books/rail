defmodule Rail.Runs.Utils.GetFollowerPidTest do
  use Rail.DataCase, async: true

  import Rail.Runs.Utils.GetFollowerPid

  alias Rail.Backends.Schemas.Backend
  alias Rail.Runs
  alias Rail.Runs.FollowerSupervisor
  alias Rail.Runs.Schemas.OsProcess

  test "returns nil when no follower is registered" do
    assert is_nil(get_follower_pid("osp_nonexistent"))
  end

  test "finds a live follower by its os process id" do
    tmp_dir = Path.join(System.tmp_dir!(), "get_follower_pid_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    stream_path = Path.join(tmp_dir, "stream.ndjson")
    File.write!(stream_path, "")

    {:ok, run} =
      Runs.create_run(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })

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

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(
        os_process: os_process,
        backend: %Backend{name: :claude},
        run: run,
        stream_path: stream_path
      )

    on_exit(fn -> FollowerSupervisor.stop_follower(follower_pid) end)

    assert get_follower_pid(os_process.id) == follower_pid
    assert get_follower_pid(os_process.id) == follower_pid
  end
end
