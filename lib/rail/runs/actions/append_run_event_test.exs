defmodule Rail.Runs.Actions.AppendRunEventTest do
  use Rail.DataCase, async: true

  alias Rail.Runs
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent

  setup do
    {:ok, run} =
      Runs.create_run(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })

    %{run: run}
  end

  test "takes a run struct or an id and keeps the log in order", %{run: run} do
    assert %RunEvent{line: "from struct", seq: first} = Runs.append_run_event(run, "from struct")
    assert %RunEvent{line: "from id", seq: second} = Runs.append_run_event(run, "from id")

    # The position is the database's to assign; all this asks is that it advances.
    assert is_integer(first)
    assert second > first
  end

  test "leaves the line on the run rather than any one of its processes", %{run: run} do
    assert %RunEvent{os_process_id: nil} = Runs.append_run_event(run, "[rail] between turns")
  end

  test "broadcasts the event on the run topic", %{run: %Run{id: run_id} = run} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run_id}")

    event = Runs.append_run_event(run, "broadcast me")

    assert_receive {:run_events, ^run_id, [^event]}
  end
end
