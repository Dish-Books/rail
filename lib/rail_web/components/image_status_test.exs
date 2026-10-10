defmodule RailWeb.Components.ImageStatusTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.ImageStatus

  test "reads Current" do
    assert render_component(&ImageStatus.image_status/1, id: "i", image: :current) =~ "Current"
  end

  test "reads Copying, with the gigabytes sent of the total once the total is known" do
    html = render_component(&ImageStatus.image_status/1, id: "i", image: {:copying, 1_503_238_554, 2_254_857_830})
    assert html =~ "Copying"
    assert html =~ "1.4 of 2.1 GB"

    html = render_component(&ImageStatus.image_status/1, id: "i", image: {:copying, 0, nil})
    assert html =~ "Copying"
    refute html =~ "GB"
  end

  test "reads Copy failed with why" do
    html = render_component(&ImageStatus.image_status/1, id: "i", image: {:failed, "no space left on device"})
    assert html =~ "Copy failed"
    assert html =~ "no space left on device"
  end

  test "is a dash for a host never reached" do
    assert render_component(&ImageStatus.image_status/1, id: "i", image: nil) =~ "—"
  end
end
