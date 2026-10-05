defmodule Rail.Tools.Utils.NewEventStateTest do
  use Rail.DataCase, async: true

  import Rail.Tools.Utils.NewEventState

  alias Rail.Tools.ClaudeEvents
  alias Rail.Tools.CommandEvents
  alias Rail.Tools.Schemas.Backend

  test "a backend's stream gets Claude's accumulator" do
    assert %ClaudeEvents{} = new_event_state(%Backend{name: :claude})
  end

  test "a command's output gets a state with nothing to accumulate" do
    assert %CommandEvents{saw_result: false, usage: nil} = new_event_state(:command)
  end

  test "carries the opts onto the state" do
    assert %ClaudeEvents{conversation_id: "sess_1"} = new_event_state(%Backend{name: :claude}, conversation_id: "sess_1")
  end
end
