defmodule Rail.Tools.Actions.ParseStreamTest do
  use Rail.DataCase, async: true

  alias Rail.Tools
  alias Rail.Tools.ClaudeEvents

  test "reads lines into the backend's event state, oldest first" do
    assert %ClaudeEvents{logs: ["first", "second"]} = Tools.parse_stream(:claude, ["first", "second"])
  end

  test "seeds the state from opts" do
    assert %ClaudeEvents{conversation_id: "sess_1"} =
             Tools.parse_stream(:claude, [], conversation_id: "sess_1")
  end

  test "reads on from a state an earlier call returned" do
    held = Tools.parse_stream(:claude, ["first"], conversation_id: "sess_1")

    assert %ClaudeEvents{conversation_id: "sess_1", logs: ["first", "second"]} =
             Tools.parse_stream(:claude, ["second"], from: held)
  end
end
