defmodule Rail.ApplicationTest do
  # Serial: these swap adoption on boot in the application env.
  use Rail.DataCase, async: false

  alias Rail.Tools
  alias Rail.Tools.Schemas.Restart

  test "records the stop as Rail goes down, so the restart knows how long it was away" do
    Application.put_env(:rail, :adopt_on_boot, true)
    on_exit(fn -> Application.put_env(:rail, :adopt_on_boot, false) end)

    assert :state = Rail.Application.prep_stop(:state)
    assert {:ok, %Restart{stopped_at: %DateTime{}, started_at: nil}} = Tools.get_latest_restart()
  end

  test "records nothing where nothing is adopted on boot" do
    assert :state = Rail.Application.prep_stop(:state)
    assert {:error, :not_found} = Tools.get_latest_restart()
  end
end
