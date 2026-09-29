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

  test "lists the line oldest first, with what each row belongs to", %{run: %{id: run_id} = run} do
    now = DateTime.utc_now()

    [%OsProcess{id: younger_id}, %OsProcess{id: older_id}] =
      for queued_at <- [now, DateTime.shift(now, minute: -1)] do
        Repo.insert!(%OsProcess{
          run_id: run.id,
          task_id: run.task_id,
          stream_path: "/dev/null",
          status: :waiting_for_resources,
          started_at: now,
          queued_at: queued_at,
          reserved_cpus: 1,
          reserved_memory_gb: 2
        })
      end

    assert [%OsProcess{id: ^older_id, run: %{id: ^run_id}}, %OsProcess{id: ^younger_id}] =
             Tools.list_os_processes(status: [:waiting_for_resources], order: :queue, preload: [:run])
  end

  test "lists the sandboxes that ended since a time, and only sandboxes", %{run: run} do
    now = DateTime.utc_now()

    %OsProcess{id: recent_id} =
      Repo.insert!(%OsProcess{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/dev/null",
        status: :finished,
        started_at: now,
        ended_at: now,
        reserved_cpus: 1,
        reserved_memory_gb: 2
      })

    Repo.insert!(%OsProcess{
      run_id: run.id,
      task_id: run.task_id,
      stream_path: "/dev/null",
      status: :finished,
      started_at: now,
      ended_at: DateTime.shift(now, hour: -2),
      reserved_cpus: 1,
      reserved_memory_gb: 2
    })

    assert [%OsProcess{id: ^recent_id}] =
             Tools.list_os_processes(ended_after: DateTime.shift(now, hour: -1), sandboxed: true)

    assert [] = Tools.list_os_processes(status: [:running], sandboxed: true)
  end
end
