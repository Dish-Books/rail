defmodule Rail.Runs.Actions.ListRunEventsTest do
  use Rail.DataCase, async: true

  alias Rail.Runs

  setup do
    {:ok, run} =
      Runs.create_run(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })

    for line <- ["line 1", "line 2", "line 3"] do
      Runs.append_run_event(run, line)
    end

    %{run: run}
  end

  test "orders by seq and honours the limit", %{run: run} do
    assert Enum.map(Runs.list_run_events(run), & &1.line) == ["line 1", "line 2", "line 3"]
    assert length(Runs.list_run_events(run, limit: 2)) == 2
  end
end
