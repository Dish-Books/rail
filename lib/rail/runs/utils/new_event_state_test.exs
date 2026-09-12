defmodule Rail.Runs.Utils.NewEventStateTest do
  use Rail.DataCase, async: true

  import Rail.Runs.Utils.NewEventState

  alias Rail.Backends.Schemas.Backend
  alias Rail.Runs.AgyEvents
  alias Rail.Runs.ClaudeEvents

  test "picks the accumulator for the backend" do
    assert %ClaudeEvents{} = new_event_state(%Backend{name: :claude})
    assert %AgyEvents{} = new_event_state(%Backend{name: :agy})
  end

  test "carries the opts onto the state" do
    assert %ClaudeEvents{task_id: "tsk_1"} = new_event_state(%Backend{name: :claude}, task_id: "tsk_1")
  end
end
