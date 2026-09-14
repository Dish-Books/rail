defmodule Rail.Tools.Workers.RefreshUsageTest do
  use Rail.DataCase, async: true

  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Workers.RefreshUsage

  test "refreshes every configured backend" do
    expect(Tools, :refresh_usage, fn -> {:ok, [%Backend{name: :claude}]} end)

    assert :ok = RefreshUsage.perform(%Oban.Job{args: %{}})
  end

  test "stays :ok when a probe fails, so the next run is not blocked" do
    expect(Tools, :refresh_usage, fn -> {:error, :timeout} end)

    assert :ok = RefreshUsage.perform(%Oban.Job{args: %{}})
  end
end
