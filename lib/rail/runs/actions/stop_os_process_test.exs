defmodule Rail.Runs.Actions.StopOsProcessTest do
  use Rail.DataCase, async: true

  alias Rail.Runs
  alias Rail.Runs.Schemas.OsProcess

  setup do
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
        stream_path: "/tmp/stop_os_process.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    %{run: run, os_process: os_process}
  end

  test "settles an os process with no live follower", %{run: run, os_process: os_process} do
    assert Runs.is_running?(run.task_id)
    assert {:ok, %OsProcess{status: :finished}} = Runs.stop_os_process(os_process, grace_period: 50)
    refute Runs.is_running?(run.task_id)
  end
end
