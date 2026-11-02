defmodule RailWebTest do
  use ExUnit.Case, async: true

  test "static_paths returns list of static paths" do
    paths = RailWeb.static_paths()
    assert "assets" in paths
  end

  # These run as a module compiles, which is before a test run starts counting.
  test "each kind of module uses what Phoenix offers for it" do
    assert Macro.to_string(RailWeb.router()) =~ "use Phoenix.Router"
    assert Macro.to_string(RailWeb.channel()) =~ "use Phoenix.Channel"
    assert Macro.to_string(RailWeb.controller()) =~ "use Phoenix.Controller"
    assert Macro.to_string(RailWeb.live_view()) =~ "use Phoenix.LiveView"
    assert Macro.to_string(RailWeb.live_component()) =~ "use Phoenix.LiveComponent"
    assert Macro.to_string(RailWeb.html()) =~ "use Phoenix.Component"
  end
end
