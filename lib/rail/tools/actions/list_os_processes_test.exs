defmodule Rail.Tools.Actions.ListOsProcessesTest do
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

    %OsProcess{id: running_id} =
      running =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/list_os_processes_running.ndjson",
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    finished =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/list_os_processes_finished.ndjson",
        status: :finished,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    %{run: run, running: running, running_id: running_id, finished: finished}
  end

  test "filters by run, task and status", %{run: run, running_id: running_id} do
    assert length(Tools.list_os_processes(run_id: run.id)) == 2
    assert length(Tools.list_os_processes(task_id: run.task_id)) == 2

    assert [%OsProcess{id: ^running_id}] = Tools.list_os_processes(run_id: run.id, status: :running)
  end

  test "ignores unknown filters", %{run: run} do
    assert length(Tools.list_os_processes(run_id: run.id, ignore_unknown: true)) == 2
  end
end
