defmodule Rail.Tools.Utils.ParseLineTest do
  use Rail.DataCase, async: true

  import Rail.Tools.Utils.NewEventState
  import Rail.Tools.Utils.ParseLine

  alias Rail.Tools.Schemas.Backend

  test "dispatches on the state struct" do
    claude = new_event_state(%Backend{name: :claude})
    assert parse_line(claude, "banner message").logs == ["banner message"]

    agy = new_event_state(%Backend{name: :agy})
    assert parse_line(agy, "agy message").logs == ["agy message"]
  end
end
