defmodule Rail.Tools.Actions.RecordRailStopTest do
  use Rail.DataCase, async: true

  alias Rail.Tools
  alias Rail.Tools.Schemas.Restart

  test "records when Rail went down, as a restart still waiting to come back" do
    assert {:ok, %Restart{stopped_at: %DateTime{}, started_at: nil, sandboxes_kept: nil}} = Tools.record_rail_stop()
  end
end
