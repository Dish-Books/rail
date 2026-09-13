defmodule Rail.Tools.Actions.ParseStreamTest do
  use Rail.DataCase, async: true

  alias Rail.Tools
  alias Rail.Tools.AgyEvents
  alias Rail.Tools.ClaudeEvents
  alias Rail.Tools.Schemas.Backend

  test "reads lines into the backend's event state, oldest first" do
    assert %ClaudeEvents{logs: ["first", "second"]} = Tools.parse_stream(%Backend{name: :claude}, ["first", "second"])
  end

  test "picks the parser from the backend" do
    assert %AgyEvents{} = Tools.parse_stream(%Backend{name: :agy}, [])
  end

  test "seeds the state from opts" do
    assert %ClaudeEvents{conversation_id: "sess_1"} =
             Tools.parse_stream(%Backend{name: :claude}, [], conversation_id: "sess_1")
  end
end
