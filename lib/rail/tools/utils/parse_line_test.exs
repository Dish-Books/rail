defmodule Rail.Tools.Utils.ParseLineTest do
  use Rail.DataCase, async: true

  import Rail.Tools.Utils.NewEventState
  import Rail.Tools.Utils.ParseLine

  test "dispatches on the state struct" do
    claude = new_event_state(:claude)
    assert parse_line(claude, "banner message").logs == ["banner message"]

    command = new_event_state(:command)
    assert parse_line(command, "compiling 3 files") == command
  end
end
