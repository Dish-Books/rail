defmodule RailWeb.Components.ScreenCompareTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.ScreenCompare

  # A shot saved once its worktree was gone has no commit, so the list names it by its place.
  test "an earlier shot on no commit is offered by its place, and the latest says none" do
    screen = %{
      key: "toolbar",
      label: "Toolbar",
      findings: [],
      shots: [
        %{
          index: 0,
          file: "screens/toolbar/1.jpg",
          label: "Toolbar",
          commit: nil,
          browser: nil,
          taken_at: ~U[2026-10-07 16:00:00Z]
        },
        %{
          index: 1,
          file: "screens/toolbar/2.jpg",
          label: "Toolbar",
          commit: nil,
          browser: nil,
          taken_at: ~U[2026-10-08 09:00:00Z]
        }
      ]
    }

    doc =
      (&ScreenCompare.screen_compare/1)
      |> render_component(task_id: "tsk_1", screens: [screen], open: "toolbar", earlier: 0, target: nil)
      |> Floki.parse_fragment!()

    assert ["Shot 1"] = doc |> Floki.find("[data-qa=screen_earlier] option") |> Enum.map(&String.trim(Floki.text(&1)))
    assert [] = Floki.find(doc, "[data-qa=review_screens_on]")
    assert [] = Floki.find(doc, "[data-qa=screen_latest] figcaption .font-mono")
  end
end
