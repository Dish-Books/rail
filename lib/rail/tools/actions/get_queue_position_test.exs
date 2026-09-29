defmodule Rail.Tools.Actions.GetQueuePositionTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup do
    now = DateTime.utc_now()

    [ahead, behind] =
      for seconds_ago <- [120, 60] do
        {:ok, run} =
          Pipeline.create_run(%{
            task_id: UXID.generate!(prefix: "tsk"),
            role_id: UXID.generate!(prefix: "rol"),
            status: :waiting_for_resources,
            started_at: now
          })

        os_process =
          Repo.insert!(%OsProcess{
            run_id: run.id,
            task_id: run.task_id,
            stream_path: "/dev/null",
            status: :waiting_for_resources,
            started_at: now,
            queued_at: DateTime.shift(now, second: -seconds_ago),
            reserved_cpus: 1,
            reserved_memory_gb: 2
          })

        {run, os_process}
      end

    %{ahead: ahead, behind: behind}
  end

  test "counts the runs ahead in line, oldest first", %{
    ahead: {ahead_run, %OsProcess{id: ahead_id}},
    behind: {behind_run, %OsProcess{id: behind_id}}
  } do
    assert {:ok, %{position: 1, os_process: %OsProcess{id: ^ahead_id}}} = Tools.get_queue_position(ahead_run)
    assert {:ok, %{position: 2, os_process: %OsProcess{id: ^behind_id}}} = Tools.get_queue_position(behind_run)
  end

  test "says so for a run that is not in line", %{ahead: {_run, os_process}} do
    {:ok, running} =
      Pipeline.create_run(%{
        task_id: os_process.task_id,
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:error, :not_waiting} = Tools.get_queue_position(running)
  end
end
