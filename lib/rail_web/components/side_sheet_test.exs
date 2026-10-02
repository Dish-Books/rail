defmodule RailWeb.Components.SideSheetTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias RailWeb.Components.SideSheet

  test "holds a header beside its close button above a scrolling body, and Escape closes it" do
    assigns = %{}

    html =
      ~H"""
      <SideSheet.side_sheet id="person-sheet" label="Jordan Lee" on_close="close_sheet">
        <:header>
          <p id="sheet-name">Jordan Lee</p>
        </:header>
        <p id="sheet-body">Projects</p>
      </SideSheet.side_sheet>
      """
      |> rendered_to_string()
      |> Floki.parse_fragment!()

    assert Floki.attribute(html, "aside#person-sheet", "aria-label") == ["Jordan Lee"]
    assert Floki.attribute(html, "#person-sheet", "phx-window-keydown") == ["close_sheet"]
    assert Floki.attribute(html, "#person-sheet", "phx-key") == ["Escape"]
    assert Floki.attribute(html, "#person-sheet-close", "phx-click") == ["close_sheet"]
    assert Floki.attribute(html, "#person-sheet-close", "aria-label") == ["Close"]
    assert Floki.text(Floki.find(html, "#person-sheet #sheet-name")) == "Jordan Lee"
    assert Floki.text(Floki.find(html, "#person-sheet [data-qa='side-sheet-body'] #sheet-body")) == "Projects"
  end
end
