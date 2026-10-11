defmodule RailWeb.Components.ScreenViewTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.ScreenComment
  alias RailWeb.Components.ScreenView

  setup do
    %{
      screen: %{
        key: "file-list",
        label: "File list",
        file: "screens/file-list/2.jpg",
        commit: "e52a0bd91",
        taken_at: ~U[2026-10-08 09:00:00Z],
        findings: [%{key: "send-twice", title: "Send stays enabled"}]
      }
    }
  end

  test "shows where the state is among them, its commit, the findings citing it and the reader's comments", %{
    screen: screen
  } do
    doc =
      (&ScreenView.screen_view/1)
      |> render_component(
        task_id: "tsk_1",
        screen: screen,
        position: 1,
        count: 3,
        labels: %{"e52a0bd91" => "Fix round 1"},
        comments: [%ScreenComment{id: "scm_1", body: "It wraps."}],
        target: nil
      )
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("#screen-view-position") |> Floki.text() =~ "1 of 3"
    assert ["true"] = doc |> Floki.find("#screen-view-previous") |> Floki.attribute("aria-disabled")
    assert ["false"] = doc |> Floki.find("#screen-view-next") |> Floki.attribute("aria-disabled")
    assert doc |> Floki.find("#screen-view-panel") |> Floki.text() =~ ~r/File list\s+e52a0bd\s+Fix round 1/
    assert ["send-twice"] = doc |> Floki.find("[data-qa=screen_finding]") |> Floki.attribute("phx-value-key")
    assert doc |> Floki.find("#screen-view-comments") |> Floki.text() =~ ~r/Not sent\s+Remove\s+It wraps./
    assert ["false"] = doc |> Floki.find("#screen-view-comment") |> Floki.attribute("aria-pressed")
    assert [_bound] = Floki.find(doc, "#screen-view-panel[phx-window-keydown=screen_key]")
    assert [] = Floki.find(doc, "#screen-comment-form")
  end

  test "the last state marks Next unavailable, and one state alone has no steps", %{screen: screen} do
    doc =
      (&ScreenView.screen_view/1)
      |> render_component(task_id: "tsk_1", screen: screen, position: 3, count: 3, target: nil)
      |> Floki.parse_fragment!()

    assert ["true"] = doc |> Floki.find("#screen-view-next") |> Floki.attribute("aria-disabled")

    doc =
      (&ScreenView.screen_view/1)
      |> render_component(task_id: "tsk_1", screen: %{screen | findings: []}, position: 1, count: 1, target: nil)
      |> Floki.parse_fragment!()

    assert [] = Floki.find(doc, "#screen-view-position")
    assert [] = Floki.find(doc, "#screen-view-findings")
    assert [] = Floki.find(doc, "#screen-view-comments")
  end

  # Typing in the box must not step or close the view.
  test "with the comment box open the window keys are not bound", %{screen: screen} do
    doc =
      (&ScreenView.screen_view/1)
      |> render_component(task_id: "tsk_1", screen: screen, position: 1, count: 2, draft: "", target: nil)
      |> Floki.parse_fragment!()

    assert [_box] = Floki.find(doc, "#screen-comment-form")
    assert ["true"] = doc |> Floki.find("#screen-view-comment") |> Floki.attribute("aria-pressed")
    assert [] = Floki.find(doc, "#screen-view-panel[phx-window-keydown]")
    assert [] = Floki.find(doc, "#screen-view[phx-window-keydown]")
  end
end
