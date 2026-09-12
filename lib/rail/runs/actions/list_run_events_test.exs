defmodule Rail.Runs.Actions.ListRunEventsTest do
  use Rail.DataCase, async: true

  alias Rail.Runs
  alias Rail.Runs.Schemas.RunEvent

  setup do
    {:ok, run} =
      Runs.create_run(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })

    Repo.insert!(%RunEvent{run_id: run.id, seq: 1, line: "line 1"})
    Repo.insert!(%RunEvent{run_id: run.id, seq: 2, line: "line 2"})
    Repo.insert!(%RunEvent{run_id: run.id, seq: 3, line: "line 3"})

    %{run: run}
  end

  test "orders by seq and honours the limit", %{run: run} do
    assert Enum.map(Runs.list_run_events(run.id), & &1.seq) == [1, 2, 3]
    assert length(Runs.list_run_events(run.id, limit: 2)) == 2
  end
end
