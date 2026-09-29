defmodule RailWeb.Components.SandboxUsageMeterTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.SandboxUsageMeter

  test "flags a sandbox nearing or at the limit it cannot pass" do
    meter = fn used ->
      render_component(&SandboxUsageMeter.sandbox_usage_meter/1, id: "m", used: used, reserved: 2, unit: "CPU")
    end

    assert meter.(0.3) =~ "0.3"
    refute meter.(0.3) =~ "limit"
    assert meter.(1.9) =~ "near limit"
    assert meter.(2.0) =~ "at limit"
    assert meter.(nil) =~ "—"
  end
end
