defmodule RailWeb.Components.ScreenGridTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.ScreenGrid

  setup do
    %{
      screens: [
        %{
          key: "file-list",
          label: "File list",
          file: "screens/file-list/2.jpg",
          commit: "e52a0bd91",
          taken_at: ~U[2026-10-08 09:00:00Z],
          findings: []
        },
        %{
          key: "toolbar",
          label: "Toolbar",
          file: "screens/toolbar/1.jpg",
          commit: nil,
          taken_at: ~U[2026-10-07 09:00:00Z],
          findings: []
        }
      ]
    }
  end

  test "each state is one card with its shot, label and commit, and a state with unsent comments says how many", %{
    screens: screens
  } do
    doc =
      (&ScreenGrid.screen_grid/1)
      |> render_component(
        task_id: "tsk_1",
        screens: screens,
        labels: %{"e52a0bd91" => "Fix round 1"},
        unsent: %{"file-list" => 1},
        target: nil
      )
      |> Floki.parse_fragment!()

    assert ["screen-file-list", "screen-toolbar"] = doc |> Floki.find("[data-qa=screen_card]") |> Floki.attribute("id")
    [card] = Floki.find(doc, "#screen-file-list")
    assert Floki.text(card) =~ ~r/1 not sent\s+File list\s+e52a0bd\s*Fix round 1/
    refute Floki.text(card) =~ "earlier"
    assert ["/tasks/tsk_1/screens/file-list?at=1791450000000000"] = card |> Floki.find("img") |> Floki.attribute("src")
    assert [] = Floki.find(doc, "#screen-toolbar [data-qa=screen_card_unsent]")
    assert doc |> Floki.find("[data-qa=review_screens_on]") |> Floki.text() =~ "latest taken on e52a0bd"
  end

  test "with no screens it says so" do
    doc =
      (&ScreenGrid.screen_grid/1)
      |> render_component(task_id: "tsk_1", screens: [], target: nil)
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("[data-qa=review_screens_none]") |> Floki.text() =~ "No screens yet."
    assert [] = Floki.find(doc, "[data-qa=review_screens_on]")
  end
end
