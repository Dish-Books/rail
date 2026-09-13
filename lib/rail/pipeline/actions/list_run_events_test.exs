defmodule Rail.Pipeline.Actions.ListRunEventsTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline

  setup do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })

    Pipeline.append_run_events(run.id, nil, ["line 1", "line 2", "line 3"])

    %{run: run}
  end

  test "orders by seq and honours the limit", %{run: run} do
    assert Enum.map(Pipeline.list_run_events(run), & &1.line) == ["line 1", "line 2", "line 3"]
    assert length(Pipeline.list_run_events(run, limit: 2)) == 2
  end
end
