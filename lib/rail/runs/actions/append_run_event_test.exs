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

  test "takes a run struct or an id and keeps seq sequential", %{run: run} do
    assert %RunEvent{line: "from struct", seq: 1} = Runs.append_run_event(run, "from struct")
    assert %RunEvent{line: "from id", seq: 2} = Runs.append_run_event(run.id, "from id")
  end

  test "broadcasts the event on the run topic", %{run: %Run{id: run_id} = run} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run_id}")

    event = Runs.append_run_event(run, "broadcast me")

    assert_receive {:run_events, ^run_id, [^event]}
  end
end
