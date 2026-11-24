defmodule RailWeb.Components.ProgressBarTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.CoreComponents

  test "fills to the percent and says it to assistive tech" do
    html = render_component(&CoreComponents.progress_bar/1, percent: 33, class: "h-2")

    assert [_bar] = Floki.find(Floki.parse_fragment!(html), "[role='progressbar'][aria-valuenow='33'].h-2")
    assert html =~ "width: 33%"
  end
end
