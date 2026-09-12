defmodule Rail.Runs.Actions.ListOsProcessesTest do
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

    running =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/list_os_processes_running.ndjson",
        node: "node_under_test",
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
        node: "node_under_test",
        status: :finished,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    %{run: run, running: running, finished: finished}
  end

  test "filters by run, task, node and status", %{run: run, running: running} do
    assert length(Runs.list_os_processes(run_id: run.id)) == 2
    assert length(Runs.list_os_processes(task_id: run.task_id)) == 2
    assert length(Runs.list_os_processes(node: "node_under_test")) == 2

    assert [%OsProcess{id: id}] = Runs.list_os_processes(run_id: run.id, status: :running)
    assert id == running.id
  end

  test "ignores unknown filters", %{run: run} do
    assert length(Runs.list_os_processes(run_id: run.id, ignore_unknown: true)) == 2
  end
end
