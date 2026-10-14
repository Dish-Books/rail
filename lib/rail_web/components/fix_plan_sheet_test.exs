defmodule RailWeb.Components.FixPlanSheetTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.FixPlan
  alias RailWeb.Components.FixPlanSheet

  setup do
    plan =
      "Two changes.\n\n### What changes\n\n#### `send-drops`\n\nReads screen comments.\n\n#### `tray-count`\n\nCounts them.\n\n" <>
        "#### Comment 1\n\nKept under its line.\n\n### File-level changes\n\n" <>
        "- `lib/send.ex`: reads them. For `send-drops`.\n- `lib/tray.ex`: counts them. For `tray-count`.\n" <>
        "- `lib/diff_comment.ex`: keeps it. For comment 1.\n- `lib/send_test.exs`: all three. For `send-drops`.\n\n" <>
        "### Verification\n\n`mix test lib/send_test.exs`."

    fix_plan =
      Ecto.Changeset.apply_action!(
        FixPlan.save_changeset(
          %FixPlan{
            round: 1,
            findings: [
              %FixPlan.Finding{key: "send-drops", title: "Send leaves screen comments out"},
              %FixPlan.Finding{key: "tray-count", title: "Tray count leaves out finding comments"}
            ],
            comments: [
              %FixPlan.Comment{number: 1, kind: :diff, place: "diff_comment.ex:58", text: "Keep it under its line."}
            ]
          },
          %{"plan" => plan}
        ),
        :update
      )

    %{fix_plan: fix_plan, sheet: FixPlan.build_sheet(fix_plan)}
  end

  test "an item per finding key and comment number links its numbered files, with the plan's counts", %{sheet: sheet} do
    doc = (&FixPlanSheet.fix_plan_sheet/1) |> render_component(sheet: sheet) |> Floki.parse_fragment!()

    assert doc |> Floki.find("#fix-plan-item-send-drops") |> Floki.text() =~ "Send leaves screen comments out"
    assert ["#plan-file-1", "#plan-file-4"] = doc |> Floki.find("#fix-plan-item-send-drops a") |> Floki.attribute("href")
    assert doc |> Floki.find("#fix-plan-item-comment-1") |> Floki.text() =~ "Comment 1 · Diff"
    assert doc |> Floki.find("#fix-plan-item-comment-1") |> Floki.text() =~ "Keep it under its line."
    assert ["#plan-file-3"] = doc |> Floki.find("#fix-plan-item-comment-1 a") |> Floki.attribute("href")
    assert doc |> Floki.find("#plan-file-2") |> Floki.text() =~ "lib/tray.ex"

    counts = doc |> Floki.find("[data-qa=fix_plan_counts]") |> Floki.text() |> String.split() |> Enum.join(" ")
    assert counts == "2 findings · 1 comment · 4 files"
    assert doc |> Floki.find("#plan-summary") |> Floki.text() =~ "Both Fix findings and comment 1 covered"
    assert doc |> Floki.find("#plan-summary") |> Floki.text() =~ "Every file is named by an item"
    assert Floki.text(doc) =~ "Verification"
    assert Floki.find(doc, "[data-qa=fix_plan_item_changed]") == []
  end

  test "a covered finding now ruled Don't fix reads so at its entry", %{sheet: sheet} do
    doc =
      (&FixPlanSheet.fix_plan_sheet/1)
      |> render_component(sheet: sheet, changed: %{"tray-count" => :skip})
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("#fix-plan-item-tray-count [data-qa=fix_plan_item_changed]") |> Floki.text() =~
             "Now Don't fix"

    assert Floki.find(doc, "#fix-plan-item-send-drops [data-qa=fix_plan_item_changed]") == []
  end

  test "a plan sent on since it was saved lists what it covers with that check not ticked", %{fix_plan: fix_plan} do
    [first] = fix_plan.comments
    sent_on = %{fix_plan | comments: [first, %FixPlan.Comment{number: 2, kind: :diff, text: "And this."}]}

    doc =
      (&FixPlanSheet.fix_plan_sheet/1)
      |> render_component(sheet: FixPlan.build_sheet(sent_on))
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("#plan-summary") |> Floki.text() =~
             "Both Fix findings and comment 1 covered, before the last Send"

    assert Floki.find(doc, "#fix-plan-item-comment-2") == []
  end

  test "a plan on comments alone, with nothing to change, says what it covers and lists no files" do
    fix_plan = %FixPlan{
      round: 1,
      plan: "### What changes\n\n#### Comment 1\n\nAnswered.\n\n#### Comment 2\n\nAnswered.\n\n#### Comment 3\n\nNo.",
      comments: for(n <- 1..3, do: %FixPlan.Comment{number: n, kind: :screen, text: "Why #{n}?"}),
      covered_comments: 3
    }

    doc =
      (&FixPlanSheet.fix_plan_sheet/1)
      |> render_component(sheet: FixPlan.build_sheet(fix_plan))
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("#plan-summary") |> Floki.text() =~ "Comments 1, 2 and 3 covered"
    refute Floki.text(doc) =~ "Every file is named by an item"
    refute Floki.text(doc) =~ "File-level changes"
    assert doc |> Floki.find("#fix-plan-item-comment-2") |> Floki.text() =~ "Comment 2 · Screen"
  end

  test "the changes a person asked for are called out before the summary" do
    fix_plan = %FixPlan{
      round: 1,
      plan:
        "### Changes to the plan\n\n- Criterion 1: a dot.\n\nThe heading takes a dot.\n\n### What changes\n\n" <>
          "#### Changes to the plan\n\nThe span and the script change."
    }

    doc =
      (&FixPlanSheet.fix_plan_sheet/1)
      |> render_component(sheet: FixPlan.build_sheet(fix_plan))
      |> Floki.parse_fragment!()

    changes = doc |> Floki.find("#fix-plan-changes") |> Floki.text()
    assert changes =~ "Criterion 1: a dot."
    assert changes =~ "The span and the script change."
    assert doc |> Floki.find("#plan-summary") |> Floki.text() =~ ~r/0\s*findings/
  end

  test "one finding, or several, reads as covered with a finding comment" do
    for {count, comments, said} <- [
          {1, 1, "The Fix finding and comment 1 covered"},
          {3, 1, "All 3 Fix findings and comment 1 covered"},
          {1, 0, "The Fix finding covered"}
        ] do
      findings = for n <- 1..count, do: %FixPlan.Finding{key: "f#{n}", title: "F#{n}"}

      fix_plan = %FixPlan{
        round: 1,
        plan: "### What changes",
        findings: findings,
        comments:
          Enum.take([%FixPlan.Comment{number: 1, kind: :finding, place: "f1 · Fix", text: "Higher up."}], comments),
        covered_keys: Enum.map(findings, & &1.key),
        covered_titles: Map.new(findings, &{&1.key, &1.title}),
        covered_comments: comments
      }

      doc =
        (&FixPlanSheet.fix_plan_sheet/1)
        |> render_component(sheet: FixPlan.build_sheet(fix_plan))
        |> Floki.parse_fragment!()

      assert doc |> Floki.find("#plan-summary") |> Floki.text() =~ said
      assert comments == 0 or doc |> Floki.find("#fix-plan-item-comment-1") |> Floki.text() =~ "Comment 1 · Finding"
    end
  end
end
