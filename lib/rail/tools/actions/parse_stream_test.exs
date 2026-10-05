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
end
