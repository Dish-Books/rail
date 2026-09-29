defmodule Rail.Tools.Actions.ListRestartsTest do
  use Rail.DataCase, async: true

  alias Rail.Tools
  alias Rail.Tools.Schemas.Restart

  test "lists the restarts Rail came back from since a time, oldest first" do
    now = DateTime.utc_now()

    _earlier =
      Repo.insert!(%Restart{stopped_at: DateTime.shift(now, hour: -2), started_at: DateTime.shift(now, second: -7_190)})

    first =
      Repo.insert!(%Restart{stopped_at: DateTime.shift(now, minute: -10), started_at: DateTime.shift(now, second: -559)})

    second = Repo.insert!(%Restart{stopped_at: nil, started_at: DateTime.shift(now, minute: -1)})

    assert [^first, ^second] = Tools.list_restarts(since: DateTime.shift(now, hour: -1), unknown: true)
    assert Restart.down_seconds(first) == 41
    assert Restart.down_seconds(second) == nil
  end
end
