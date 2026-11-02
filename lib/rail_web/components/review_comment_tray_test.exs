defmodule RailWeb.Components.ReviewCommentTrayTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingComment
  alias Rail.Pipeline.Schemas.ScreenComment
  alias RailWeb.Components.ReviewCommentTray

  setup do
    %{
      fix: [
        %Finding{key: "send-twice", kind: :code, title: "Send stays enabled", file: "lib/a/tray.ex", line: 52},
        %Finding{key: "removed", kind: :screen, title: "Removed comment comes back", screen: "Plan tab"}
      ],
      finding: [
        %FindingComment{
          id: "fcm_1",
          finding: %Finding{key: "removed", title: "Removed comment comes back"},
          label: "Place 2, Plan tab",
          body: "It is the tray too."
        }
      ],
      diff: [%DiffComment{id: "dcm_1", path: "lib/a/tray.ex", line: 61, body: "Keep one hint."}],
      screen: [%ScreenComment{id: "scm_1", key: "toolbar", label: "Toolbar", commit: "e52a0bd91", body: "It wraps."}],
      gate: %{working: false, finished: false, ci_failed: false, saved: true, plan: false, emptied: false, undecided: 0}
    }
  end

  test "rows go in send order: Fix findings with Open and no Remove, then the reader's comments numbered", %{
    fix: fix,
    finding: finding,
    diff: diff,
    screen: screen,
    gate: gate
  } do
    doc =
      (&ReviewCommentTray.review_comment_tray/1)
      |> render_component(
        fix: fix,
        finding_comments: finding,
        diff_comments: diff,
        screen_comments: screen,
        gate: gate,
        target: nil
      )
      |> Floki.parse_fragment!()

    assert [
             "review-tray-finding-send-twice",
             "review-tray-finding-removed",
             "review-tray-finding-fcm_1",
             "review-tray-diff-dcm_1",
             "review-tray-screen-scm_1"
           ] =
             doc |> Floki.find("[data-qa=review_tray_finding], [data-qa=review_tray_comment]") |> Floki.attribute("id")

    [finding] = Floki.find(doc, "#review-tray-finding-send-twice")
    assert Floki.text(finding) =~ ~r/Fix finding\s+tray.ex:52\s+Open/
    assert [] = Floki.find(finding, "[data-qa=remove_review_tray_comment]")
    assert doc |> Floki.find("#review-tray-finding-removed") |> Floki.text() =~ "Plan tab"

    [finding_row] = Floki.find(doc, "#review-tray-finding-fcm_1")

    assert Floki.text(finding_row) =~
             ~r/1\s+Finding\s+Removed comment comes back\s*·\s*Place 2, Plan tab\s*Remove\s+It is the tray too./

    assert ["removed"] =
             finding_row |> Floki.find("[data-qa=review_tray_finding_comment]") |> Floki.attribute("phx-value-key")

    assert ["finding"] =
             finding_row |> Floki.find("[data-qa=remove_review_tray_comment]") |> Floki.attribute("phx-value-kind")

    [diff_row] = Floki.find(doc, "#review-tray-diff-dcm_1")
    assert Floki.text(diff_row) =~ ~r/2\s+Diff\s+tray.ex:61\s+Remove\s+Keep one hint./

    [screen_row] = Floki.find(doc, "#review-tray-screen-scm_1")
    assert Floki.text(screen_row) =~ ~r/3\s+Screen\s+Toolbar\s+e52a0bd\s+Remove\s+It wraps./
    assert screen_row |> Floki.find("[data-qa=review_tray_screen]") |> Floki.attribute("phx-value-key") == ["toolbar"]

    assert doc |> Floki.find("#review-send-tray") |> Floki.text() =~ ~r/Not sent\s+5\s+your comments only you see/
    assert doc |> Floki.find("#send-review-tray:not([disabled])") |> Floki.text() =~ "Send 5"

    assert doc |> Floki.find("#review-send-tray-hint") |> Floki.text() =~
             "The Review lead is idle and starts a fix round on these at once."
  end

  test "each hint reads for the gate's state", %{fix: fix, diff: diff, gate: gate} do
    for {assigns, said, disabled} <- [
          {%{gate: %{gate | working: true}}, "The Review lead is working. Send waits until it stops.", true},
          {%{gate: %{gate | saved: false}}, "Send waits for the first round to finish.", true},
          {%{fix: []}, "Nothing to fix. Send starts a fix round on your comments.", false},
          {%{fix: [], gate: %{gate | finished: true}},
           "The review is finished. Send reopens it with a fix round on your comments.", false},
          {%{error: "Dispatch is off."}, "Dispatch is off.", false}
        ] do
      attrs =
        Map.merge(
          %{fix: fix, finding_comments: [], diff_comments: diff, screen_comments: [], gate: gate, target: nil},
          assigns
        )

      doc = (&ReviewCommentTray.review_comment_tray/1) |> render_component(attrs) |> Floki.parse_fragment!()

      assert doc |> Floki.find("#review-send-tray-hint") |> Floki.text() =~ said
      assert Floki.find(doc, "#send-review-tray[disabled]") != [] == disabled
    end
  end

  test "the working hint pulses green" do
    gate = %{working: true, finished: false, ci_failed: false, saved: true, plan: false, emptied: false, undecided: 0}

    doc =
      (&ReviewCommentTray.review_comment_tray/1)
      |> render_component(fix: [], finding_comments: [], diff_comments: [], screen_comments: [], gate: gate, target: nil)
      |> Floki.parse_fragment!()

    assert [_dot] = Floki.find(doc, "#review-send-tray-hint .bg-green-500")
  end

  test "empty while the review is open it offers Finish review, which CI failing on the fix holds", %{gate: gate} do
    attrs = %{fix: [], finding_comments: [], diff_comments: [], screen_comments: [], gate: gate, target: nil}
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

    doc =
      (&ReviewCommentTray.review_comment_tray/1)
      |> render_component(%{attrs | gate: %{gate | undecided: 2}})
      |> Floki.parse_fragment!()

    assert [_finish] = Floki.find(doc, "#finish-review[disabled]")

    assert doc |> Floki.find("#review-send-tray-hint") |> Floki.text() =~
             "Rule every finding before the review can finish: 2 still need a ruling."
  end

  test "empty while the lead works it offers neither Send nor Finish review", %{gate: gate} do
    doc =
      (&ReviewCommentTray.review_comment_tray/1)
      |> render_component(
        fix: [],
        finding_comments: [],
        diff_comments: [],
        screen_comments: [],
        gate: %{gate | working: true},
        target: nil
      )
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("#review-send-tray") |> Floki.text() =~ "Nothing to send"
    assert [] = Floki.find(doc, "#finish-review, #send-review-tray")
    assert doc |> Floki.find("#review-send-tray-hint") |> Floki.text() =~ "The Review lead is working."
  end

  # The longest hints and a refused Send's reasons run past the tray's width.
  test "the hint wraps rather than cutting off", %{diff: diff, gate: gate} do
    doc =
      (&ReviewCommentTray.review_comment_tray/1)
      |> render_component(
        fix: [],
        finding_comments: [],
        diff_comments: diff,
        screen_comments: [],
        gate: %{gate | finished: true},
        target: nil
      )
      |> Floki.parse_fragment!()

    assert [_hint] = Floki.find(doc, "#review-send-tray-hint")
    assert [] = Floki.find(doc, "#review-send-tray-hint .truncate")
  end

  test "finding comments alone are the reader's comments, and the hint reads for comments", %{
    finding: finding,
    gate: gate
  } do
    doc =
      (&ReviewCommentTray.review_comment_tray/1)
      |> render_component(
        fix: [],
        finding_comments: finding,
        diff_comments: [],
        screen_comments: [],
        gate: %{gate | finished: true},
        target: nil
      )
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("#review-send-tray") |> Floki.text() =~ ~r/Not sent\s+1\s+your comments only you see/
    assert doc |> Floki.find("#send-review-tray:not([disabled])") |> Floki.text() =~ "Send 1"

    assert doc |> Floki.find("#review-send-tray-hint") |> Floki.text() =~
             "The review is finished. Send reopens it with a fix round on your comments."
  end

  test "empty once the review is finished it draws nothing", %{gate: gate} do
    assert render_component(&ReviewCommentTray.review_comment_tray/1,
             fix: [],
             finding_comments: [],
             diff_comments: [],
             screen_comments: [],
             gate: %{gate | finished: true},
             target: nil
           ) =~ ~r/\A\s*\z/
  end

  test "folded hides the rows and keeps the header and the hint", %{fix: fix, diff: diff, gate: gate} do
    doc =
      (&ReviewCommentTray.review_comment_tray/1)
      |> render_component(
        fix: fix,
        finding_comments: [],
        diff_comments: diff,
        screen_comments: [],
        gate: gate,
        open: false,
        target: nil
      )
      |> Floki.parse_fragment!()

    assert ["false"] = doc |> Floki.find("#review-send-tray-fold") |> Floki.attribute("aria-expanded")
    assert [] = Floki.find(doc, "[data-qa=review_tray_finding], [data-qa=review_tray_comment]")
    assert doc |> Floki.find("#send-review-tray") |> Floki.text() =~ "Send 3"
    assert [_hint] = Floki.find(doc, "#review-send-tray-hint")
  end

  describe "while a fix plan waits" do
    test "lists only changed rulings, with Open and no Remove, then new comments, and offers no Finish review", %{
      diff: diff,
      gate: gate
    } do
      rulings = [%{key: "tray-count", title: "Tray count leaves out finding comments", was: :fix, now: :skip}]

      doc =
        (&ReviewCommentTray.review_comment_tray/1)
        |> render_component(
          fix: [],
          rulings: rulings,
          finding_comments: [],
          diff_comments: diff,
          screen_comments: [],
          gate: %{gate | plan: true},
          target: nil
        )
        |> Floki.parse_fragment!()

      ruling = Floki.find(doc, "#review-tray-ruling-tray-count")
      assert Floki.text(ruling) =~ "Ruling changed"
      assert Floki.text(ruling) =~ "Don't fix, was Fix"
      assert Floki.text(ruling) =~ "Tray count leaves out finding comments"
      assert Floki.text(ruling) =~ "Open"
      refute Floki.text(ruling) =~ "Remove"
      assert doc |> Floki.find("#send-review-tray") |> Floki.text() =~ "Send 2"
      assert Floki.find(doc, "#review-tray-finding-send-twice") == []
      assert Floki.find(doc, "#finish-review") == []

      assert doc |> Floki.find("#review-send-tray-hint") |> Floki.text() =~
               "The fix plan is out of date. Send asks the lead to revise it."
    end

    # Send would finish such a review anyway, so the tray says so rather than promising a revised plan.
    test "with the rulings leaving the plan nothing to fix it offers Finish review, which drops the plan", %{gate: gate} do
      rulings = [%{key: "tray-count", title: "Tray count leaves out finding comments", was: :fix, now: :skip}]
      emptied = %{gate | plan: true, emptied: true}

      attrs = %{
        fix: [],
        rulings: rulings,
        finding_comments: [],
        diff_comments: [],
        screen_comments: [],
        gate: emptied,
        target: nil
      }

      doc = (&ReviewCommentTray.review_comment_tray/1) |> render_component(attrs) |> Floki.parse_fragment!()

      assert doc |> Floki.find("#review-tray-ruling-tray-count") |> Floki.text() =~ "Don't fix, was Fix"
      assert [_finish] = Floki.find(doc, "#finish-review:not([disabled])")
      assert Floki.find(doc, "#send-review-tray") == []

      assert doc |> Floki.find("#review-send-tray-hint") |> Floki.text() =~
               "Nothing is ruled Fix now. Finish review drops the fix plan and closes the review."

      doc =
        (&ReviewCommentTray.review_comment_tray/1)
        |> render_component(%{attrs | rulings: [], gate: %{emptied | undecided: 1}})
        |> Floki.parse_fragment!()

      assert [_finish] = Floki.find(doc, "#finish-review[disabled]")
      assert doc |> Floki.find("#review-send-tray-hint") |> Floki.text() =~ "1 still needs a ruling."

      # A comment still asks for a revised plan.
      doc =
        (&ReviewCommentTray.review_comment_tray/1)
        |> render_component(%{attrs | diff_comments: [%DiffComment{id: "dcm_1", path: "lib/a.ex", line: 3, body: "Hm."}]})
        |> Floki.parse_fragment!()

      assert Floki.find(doc, "#finish-review") == []
      assert doc |> Floki.find("#send-review-tray") |> Floki.text() =~ "Send 2"
    end

    test "with nothing changed it says what a Send would do, and still offers no Finish review", %{gate: gate} do
      doc =
        (&ReviewCommentTray.review_comment_tray/1)
        |> render_component(
          fix: [],
          rulings: [%{key: "focus", title: "Composer keeps focus", was: :skip, now: :fix}],
          finding_comments: [],
          diff_comments: [],
          screen_comments: [],
          gate: %{gate | plan: true},
          target: nil
        )
        |> Floki.parse_fragment!()

      assert doc |> Floki.find("#review-tray-ruling-focus") |> Floki.text() =~ "Fix, was Don't fix"

      doc =
        (&ReviewCommentTray.review_comment_tray/1)
        |> render_component(
          fix: [],
          finding_comments: [],
          diff_comments: [],
          screen_comments: [],
          gate: %{gate | plan: true},
          target: nil
        )
        |> Floki.parse_fragment!()

      assert doc |> Floki.find("#review-send-tray") |> Floki.text() =~ "Nothing to send"
      assert Floki.find(doc, "#finish-review") == []

      assert doc |> Floki.find("#review-send-tray-hint") |> Floki.text() =~
               "Changed rulings and comments you send now go to the lead, which saves a revised fix plan in place of this one."
    end
  end

  describe "new issues" do
    setup do
      %{
        new_issues: [
          %Finding{key: "resort", kind: :code, title: "Issues page re-sorts", file: "lib/x/issues_live.ex", line: 214},
          %Finding{key: "branch", kind: :screen, title: "A long branch name overflows", screen: "Task page, header"}
        ]
      }
    end

    test "each gets a New issue row after the Fix rows that opens it, counted toward Send", %{
      fix: fix,
      diff: diff,
      gate: gate,
      new_issues: new_issues
    } do
      doc =
        (&ReviewCommentTray.review_comment_tray/1)
        |> render_component(
          fix: fix,
          new_issues: new_issues,
          finding_comments: [],
          diff_comments: diff,
          screen_comments: [],
          gate: gate,
          target: nil
        )
        |> Floki.parse_fragment!()

      assert [
               "review-tray-finding-send-twice",
               "review-tray-finding-removed",
               "review-tray-new-issue-resort",
               "review-tray-new-issue-branch",
               "review-tray-diff-dcm_1"
             ] =
               doc
               |> Floki.find(
                 "[data-qa=review_tray_finding], [data-qa=review_tray_new_issue], [data-qa=review_tray_comment]"
               )
               |> Floki.attribute("id")

      row = Floki.find(doc, "#review-tray-new-issue-resort")
      assert Floki.text(row) =~ ~r/New issue\s+issues_live.ex:214\s+Open\s+Issues page re-sorts/
      assert ["open_tray_finding"] = Floki.attribute(row, "phx-click")
      assert ["resort"] = Floki.attribute(row, "phx-value-key")
      assert doc |> Floki.find("#send-review-tray:not([disabled])") |> Floki.text() =~ "Send 5"

      assert doc |> Floki.find("#review-send-tray-hint") |> Floki.text() =~
               "The Review lead is idle and starts a fix round on these at once, and files 2 new issues."

      doc =
        (&ReviewCommentTray.review_comment_tray/1)
        |> render_component(
          fix: [],
          new_issues: tl(new_issues),
          finding_comments: [],
          diff_comments: diff,
          screen_comments: [],
          gate: gate,
          target: nil
        )
        |> Floki.parse_fragment!()

      assert doc |> Floki.find("#review-send-tray-hint") |> Floki.text() =~
               "Nothing to fix. Send starts a fix round on your comments, and files 1 new issue."
    end

    test "alone they leave Finish review offered, which files them, held by CI and by findings left to rule", %{
      gate: gate,
      new_issues: new_issues
    } do
      attrs = %{
        fix: [],
        new_issues: new_issues,
        finding_comments: [],
        diff_comments: [],
        screen_comments: [],
        gate: gate,
        target: nil
      }

      doc = (&ReviewCommentTray.review_comment_tray/1) |> render_component(attrs) |> Floki.parse_fragment!()

      assert doc |> Floki.find("#review-send-tray") |> Floki.text() =~ ~r/Not sent\s+2/
      assert [_finish] = Floki.find(doc, "#finish-review:not([disabled])")
      assert [] = Floki.find(doc, "#send-review-tray")
      assert [_one, _two] = Floki.find(doc, "[data-qa=review_tray_new_issue]")

      assert doc |> Floki.find("#review-send-tray-hint") |> Floki.text() =~
               "Finish review files 2 new issues and closes the review."

      doc =
        (&ReviewCommentTray.review_comment_tray/1)
        |> render_component(%{attrs | gate: %{gate | ci_failed: true}})
        |> Floki.parse_fragment!()

      assert [_finish] = Floki.find(doc, "#finish-review[disabled]")
      assert doc |> Floki.find("#review-send-tray-hint") |> Floki.text() =~ "CI failed on the fix commit"

      doc =
        (&ReviewCommentTray.review_comment_tray/1)
        |> render_component(%{attrs | gate: %{gate | undecided: 1}})
        |> Floki.parse_fragment!()

      assert [_finish] = Floki.find(doc, "#finish-review[disabled]")
      assert doc |> Floki.find("#review-send-tray-hint") |> Floki.text() =~ "1 still needs a ruling."
    end

    test "while a plan waits they still show, and say what Send does with them", %{gate: gate, new_issues: new_issues} do
      attrs = %{
        fix: [],
        new_issues: new_issues,
        finding_comments: [],
        diff_comments: [],
        screen_comments: [],
        gate: %{gate | plan: true},
        target: nil
      }

      doc = (&ReviewCommentTray.review_comment_tray/1) |> render_component(attrs) |> Floki.parse_fragment!()

      assert [_one, _two] = Floki.find(doc, "[data-qa=review_tray_new_issue]")
      assert doc |> Floki.find("#send-review-tray:not([disabled])") |> Floki.text() =~ "Send 2"

      assert doc |> Floki.find("#review-send-tray-hint") |> Floki.text() =~
               "Send files 2 new issues and leaves the fix plan waiting on approval."

      rulings = [%{key: "tray-count", title: "Tray count", was: :fix, now: :new_issue}]

      doc =
        (&ReviewCommentTray.review_comment_tray/1)
        |> render_component(Map.put(%{attrs | new_issues: tl(new_issues)}, :rulings, rulings))
        |> Floki.parse_fragment!()

      assert doc |> Floki.find("#review-tray-ruling-tray-count") |> Floki.text() =~ "New issue, was Fix"

      assert doc |> Floki.find("#review-send-tray-hint") |> Floki.text() =~
               "The fix plan is out of date. Send asks the lead to revise it, and files 1 new issue."

      doc =
        (&ReviewCommentTray.review_comment_tray/1)
        |> render_component(%{attrs | gate: %{gate | plan: true, emptied: true}})
        |> Floki.parse_fragment!()

      assert [_finish] = Floki.find(doc, "#finish-review:not([disabled])")

      assert doc |> Floki.find("#review-send-tray-hint") |> Floki.text() =~
               "Nothing is ruled Fix now. Finish review drops the fix plan, files 2 new issues and closes the review."
    end
  end
end
