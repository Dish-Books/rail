defmodule Rail.Tools.Actions.GetLatestRestartTest do
  use Rail.DataCase, async: true

  alias Rail.Tools
  alias Rail.Tools.Schemas.Restart

  test "reads the newest restart" do
    _older = Repo.insert!(%Restart{stopped_at: DateTime.shift(DateTime.utc_now(), minute: -10)})
    {:ok, newest} = Tools.record_rail_stop()

    assert {:ok, ^newest} = Tools.get_latest_restart()
  end

  test "has none before Rail ever stopped" do
    assert {:error, :not_found} = Tools.get_latest_restart()
  end
end
