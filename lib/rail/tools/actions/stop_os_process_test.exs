defmodule Rail.Tools.Actions.StopOsProcessTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup do
    {:ok, run} =
      Pipeline.create_run(%{
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
    assert {:ok, %OsProcess{}} = Tools.get_active_os_process(run)
    assert {:ok, %OsProcess{status: :finished}} = Tools.stop_os_process(os_process, grace_period: 50)
    assert {:error, :os_process_not_active} = Tools.get_active_os_process(run)
  end
end
