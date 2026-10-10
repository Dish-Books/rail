defmodule RailWeb.Components.ReviewCommentTrayTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.ScreenComment
  alias RailWeb.Components.ReviewCommentTray

  setup do
    %{
      fix: [
        %Finding{key: "send-twice", kind: :code, title: "Send stays enabled", file: "lib/a/tray.ex", line: 52},
        %Finding{key: "removed", kind: :screen, title: "Removed comment comes back", screen: "Plan tab"}
      ],
      diff: [%DiffComment{id: "dcm_1", path: "lib/a/tray.ex", line: 61, body: "Keep one hint."}],
      screen: [%ScreenComment{id: "scm_1", key: "toolbar", label: "Toolbar", commit: "e52a0bd91", body: "It wraps."}],
      gate: %{working: false, undecided: 0, finished: false, ci_failed: false, saved: true}
    }
  end

  test "rows go in send order: Fix findings with Open and no Remove, then the reader's comments numbered", %{
    fix: fix,
    diff: diff,
    screen: screen,
    gate: gate
  } do
    doc =
      (&ReviewCommentTray.review_comment_tray/1)
      |> render_component(fix: fix, diff_comments: diff, screen_comments: screen, gate: gate, target: nil)
      |> Floki.parse_fragment!()

    assert [
             "review-tray-finding-send-twice",
             "review-tray-finding-removed",
             "review-tray-diff-dcm_1",
             "review-tray-screen-scm_1"
           ] =
             doc |> Floki.find("[data-qa=review_tray_finding], [data-qa=review_tray_comment]") |> Floki.attribute("id")

    [finding] = Floki.find(doc, "#review-tray-finding-send-twice")
    assert Floki.text(finding) =~ ~r/Fix finding\s+tray.ex:52\s+Open/
    assert [] = Floki.find(finding, "[data-qa=remove_review_tray_comment]")
    assert doc |> Floki.find("#review-tray-finding-removed") |> Floki.text() =~ "Plan tab"

    [diff_row] = Floki.find(doc, "#review-tray-diff-dcm_1")
    assert Floki.text(diff_row) =~ ~r/1\s+Diff\s+tray.ex:61\s+Remove\s+Keep one hint./

    [screen_row] = Floki.find(doc, "#review-tray-screen-scm_1")
    assert Floki.text(screen_row) =~ ~r/2\s+Screen\s+Toolbar\s+e52a0bd\s+Remove\s+It wraps./
    assert screen_row |> Floki.find("[data-qa=review_tray_screen]") |> Floki.attribute("phx-value-key") == ["toolbar"]

    assert doc |> Floki.find("#review-send-tray") |> Floki.text() =~ ~r/Not sent\s+4\s+your comments only you see/
    assert doc |> Floki.find("#send-review-tray:not([disabled])") |> Floki.text() =~ "Send 4"

    assert doc |> Floki.find("#review-send-tray-hint") |> Floki.text() =~
             "The Review lead is idle and starts a fix round on these at once."
  end

  test "each hint reads for the gate's state", %{fix: fix, diff: diff, gate: gate} do
    for {assigns, said, disabled} <- [
          {%{gate: %{gate | working: true}}, "The Review lead is working. Send waits until it stops.", true},
          {%{gate: %{gate | undecided: 1}}, "Rule on 1 more finding before you send.", true},
          {%{gate: %{gate | undecided: 2}}, "Rule on 2 more findings before you send.", true},
          {%{gate: %{gate | saved: false}}, "Send waits for the first round to finish.", true},
          {%{fix: []}, "Nothing to fix. Send starts a fix round on your comments.", false},
          {%{fix: [], gate: %{gate | finished: true}},
           "The review is finished. Send reopens it with a fix round on your comments.", false},
          {%{error: "Dispatch is off."}, "Dispatch is off.", false}
        ] do
      attrs = Map.merge(%{fix: fix, diff_comments: diff, screen_comments: [], gate: gate, target: nil}, assigns)
      doc = (&ReviewCommentTray.review_comment_tray/1) |> render_component(attrs) |> Floki.parse_fragment!()

      assert doc |> Floki.find("#review-send-tray-hint") |> Floki.text() =~ said
      assert Floki.find(doc, "#send-review-tray[disabled]") != [] == disabled
    end
  end

  test "the working hint pulses green" do
    gate = %{working: true, undecided: 0, finished: false, ci_failed: false, saved: true}

    doc =
      (&ReviewCommentTray.review_comment_tray/1)
      |> render_component(fix: [], diff_comments: [], screen_comments: [], gate: gate, target: nil)
      |> Floki.parse_fragment!()

    assert [_dot] = Floki.find(doc, "#review-send-tray-hint .bg-green-500")
  end

  test "empty while the review is open it offers Finish review, which CI failing on the fix holds", %{gate: gate} do
    attrs = %{fix: [], diff_comments: [], screen_comments: [], gate: gate, target: nil}
    doc = (&ReviewCommentTray.review_comment_tray/1) |> render_component(attrs) |> Floki.parse_fragment!()

    assert doc |> Floki.find("#review-send-tray") |> Floki.text() =~ "Nothing to send"
    refute doc |> Floki.find("#review-send-tray") |> Floki.text() =~ "your comments only you see"
    assert [_finish] = Floki.find(doc, "#finish-review:not([disabled])")
    assert [] = Floki.find(doc, "#send-review-tray")
    assert [] = Floki.find(doc, "#review-send-tray-fold")

    assert doc |> Floki.find("#review-send-tray-hint") |> Floki.text() =~
             "Nothing to fix. Finish review closes the review."

    doc =
      (&ReviewCommentTray.review_comment_tray/1)
      |> render_component(%{attrs | gate: %{gate | ci_failed: true}})
      |> Floki.parse_fragment!()

    assert [_finish] = Floki.find(doc, "#finish-review[disabled]")
    assert doc |> Floki.find("#review-send-tray-hint") |> Floki.text() =~ "CI failed on the fix commit"
  end

  test "empty once the review is finished it draws nothing", %{gate: gate} do
    assert render_component(&ReviewCommentTray.review_comment_tray/1,
             fix: [],
             diff_comments: [],
             screen_comments: [],
             gate: %{gate | finished: true},
             target: nil
           ) =~ ~r/\A\s*\z/
  end

  test "folded hides the rows and keeps the header and the hint", %{fix: fix, diff: diff, gate: gate} do
    doc =
      (&ReviewCommentTray.review_comment_tray/1)
      |> render_component(fix: fix, diff_comments: diff, screen_comments: [], gate: gate, open: false, target: nil)
      |> Floki.parse_fragment!()

    assert ["false"] = doc |> Floki.find("#review-send-tray-fold") |> Floki.attribute("aria-expanded")
    assert [] = Floki.find(doc, "[data-qa=review_tray_finding], [data-qa=review_tray_comment]")
    assert doc |> Floki.find("#send-review-tray") |> Floki.text() =~ "Send 3"
    assert [_hint] = Floki.find(doc, "#review-send-tray-hint")
  end
end
