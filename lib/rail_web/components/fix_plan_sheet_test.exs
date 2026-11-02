defmodule RailWeb.Components.FixPlanSheetTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import RailWeb.Utils.BuildFixPlanLines

  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Projects.Schemas.Project
  alias RailWeb.Components.FixPlanSheet

  setup do
    plan =
      "Two changes.\n\n### What changes\n\n#### `send-drops`\n\nReads screen comments.\n\n#### `tray-count`\n\nCounts them.\n\n" <>
        "#### Comment 1\n\nKept under its line.\n\n### File-level changes\n\n" <>
        "#### `lib/send.ex`\n\nReads them. For `send-drops`.\n\n```elixir sketch\ndef read(comments), do: comments\n```\n\n" <>
        "#### `lib/tray.ex`\n\nCounts them. For `tray-count`.\n\n" <>
        "#### `lib/diff_comment.ex`\n\nKeeps it. For comment 1.\n\n#### `lib/send_test.exs`\n\nAll three. For `send-drops`.\n\n" <>
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

  test "an item per finding key and comment number links the cards of its files, with the plan's counts", %{sheet: sheet} do
    doc = (&FixPlanSheet.fix_plan_sheet/1) |> render_component(sheet: sheet) |> Floki.parse_fragment!()

    assert doc |> Floki.find("#fix-plan-item-send-drops") |> Floki.text() =~ "Send leaves screen comments out"
    links = Floki.find(doc, "#fix-plan-item-send-drops a")
    assert ["#fix-plan-card-1", "#fix-plan-card-4"] = Floki.attribute(links, "href")
    assert ["send.ex", "send_test.exs"] = Enum.map(links, &Floki.text/1)
    assert doc |> Floki.find("#fix-plan-item-comment-1") |> Floki.text() =~ "Comment 1 · Diff"
    assert doc |> Floki.find("#fix-plan-item-comment-1") |> Floki.text() =~ "Keep it under its line."
    assert ["#fix-plan-card-3"] = doc |> Floki.find("#fix-plan-item-comment-1 a") |> Floki.attribute("href")
    assert doc |> Floki.find("#fix-plan-card-2") |> Floki.text() =~ "lib/tray.ex"

    counts = doc |> Floki.find("[data-qa=fix_plan_counts]") |> Floki.text() |> String.split() |> Enum.join(" ")
    assert counts == "2 findings · 1 comment · 4 files"
    assert doc |> Floki.find("#plan-summary") |> Floki.text() =~ "Both Fix findings and comment 1 covered"
    assert doc |> Floki.find("#plan-summary") |> Floki.text() =~ "Every file is named by an item"
    assert Floki.text(doc) =~ "Verification"
    assert Floki.find(doc, "[data-qa=fix_plan_item_changed]") == []
  end

  test "its files are the plan's cards: grouped, marked New or Changed, and their code a click away", %{sheet: sheet} do
    project = %Project{github_repo: "example/rail", default_branch: "main"}

    doc =
      (&FixPlanSheet.fix_plan_sheet/1)
      |> render_component(sheet: sheet, default_paths: MapSet.new(["lib/tray.ex"]), project: project)
      |> Floki.parse_fragment!()

    assert [_lib] = Floki.find(doc, "#fix-plan-group-lib")
    assert doc |> Floki.find("#fix-plan-group-lib [data-qa=plan_group_count]") |> Floki.text() =~ "3 new · 1 changed"
    assert [_new] = Floki.find(doc, "#fix-plan-card-1 [data-qa=plan_card_new]")

    assert ["https://github.com/example/rail/blob/main/lib/tray.ex"] =
             doc |> Floki.find("#fix-plan-card-2 [data-qa=plan_card_link]") |> Floki.attribute("href")

    assert doc |> Floki.find("#fix-plan-card-1 [data-qa=plan_card_sketch]") |> Floki.text() =~ "Show code"
    assert doc |> Floki.find("#fix-plan-card-1 [data-qa=plan_card_sketch]") |> Floki.text() =~ "read(comments)"
    assert Floki.find(doc, "#fix-plan-card-2 [data-qa=plan_card_sketch]") == []
    assert Floki.find(doc, "[data-qa=plan_card_reviewed]") == []
  end

  test "a file the task already changed opens in Diff rather than GitHub, new or on the default branch", %{sheet: sheet} do
    project = %Project{github_repo: "example/rail", default_branch: "main"}

    doc =
      (&FixPlanSheet.fix_plan_sheet/1)
      |> render_component(
        sheet: sheet,
        default_paths: MapSet.new(["lib/tray.ex", "lib/diff_comment.ex"]),
        diff_paths: MapSet.new(["lib/send.ex", "lib/tray.ex"]),
        project: project,
        target: "#review-stage"
      )
      |> Floki.parse_fragment!()

    for card <- ["#fix-plan-card-1", "#fix-plan-card-2"] do
      [diff] = Floki.find(doc, "#{card} [data-qa=plan_card_diff]")
      assert Floki.attribute(diff, "phx-click") == ["open_diff"]
      assert Floki.attribute(diff, "phx-target") == ["#review-stage"]
      assert Floki.find(doc, "#{card} [data-qa=plan_card_link]") == []
    end

    assert doc |> Floki.find("#fix-plan-card-2 [data-qa=plan_card_diff]") |> Floki.attribute("phx-value-file") == [
             "lib/tray.ex"
           ]

    assert [_changed] = Floki.find(doc, "#fix-plan-card-2 [data-qa=plan_card_changed]")

    assert ["https://github.com/example/rail/blob/main/lib/diff_comment.ex"] =
             doc |> Floki.find("#fix-plan-card-3 [data-qa=plan_card_link]") |> Floki.attribute("href")

    assert Floki.find(doc, "#fix-plan-card-4 [data-qa=plan_card_link], #fix-plan-card-4 [data-qa=plan_card_diff]") == []
    assert Floki.text(doc) =~ "Files this task changed open in Diff, and others link to main on GitHub."
  end

  test "a reader's marks read on each card, and a card revised since its mark reads so", %{sheet: sheet} do
    %{cards: [send, tray | _rest]} = build_fix_plan_lines(sheet)
    reviewed = %{"lib/send.ex" => send.digest, "lib/tray.ex" => "1-earlier"}

    doc =
      (&FixPlanSheet.fix_plan_sheet/1)
      |> render_component(sheet: sheet, reviewed: reviewed, target: "#review-stage")
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("#fix-plan-reviewed-count") |> Floki.text() =~ "1 of 4 reviewed"
    assert ["reviewed"] = doc |> Floki.find("#fix-plan-card-1") |> Floki.attribute("data-state")
    assert ["revised"] = doc |> Floki.find("#fix-plan-card-2") |> Floki.attribute("data-state")
    assert ["unreviewed"] = doc |> Floki.find("#fix-plan-card-3") |> Floki.attribute("data-state")

    [toggle] = Floki.find(doc, "#fix-plan-card-2 [data-qa=plan_card_reviewed]")
    assert ["toggle_plan_file_reviewed"] = Floki.attribute(toggle, "phx-click")
    assert Floki.attribute(toggle, "phx-value-digest") == [tray.digest]
    assert Floki.attribute(toggle, "phx-target") == ["#review-stage"]
  end

  test "a code block and a table in its text, or in a card's, draw as code lines and table rows", %{sheet: sheet} do
    verification = "```\nmix test lib/send_test.exs\n```\n\n| Check | Result |\n|---|---|\n| Send | passes |"
    [send | files] = sheet.files
    files = [%{send | prose: "| Kind | Read |\n|---|---|\n| Screen | yes |"} | files]

    doc =
      (&FixPlanSheet.fix_plan_sheet/1)
      |> render_component(sheet: %{sheet | verification: verification, files: files})
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("[data-kind=code]") |> Floki.text() =~ "mix test lib/send_test.exs"
    assert doc |> Floki.find("[data-kind=table_row]") |> length() == 4
    assert doc |> Floki.find("#fix-plan-card-1 [data-kind=table_row]") |> length() == 2
  end

  test "a covered finding now ruled Don't fix reads so at its entry", %{sheet: sheet} do
    doc =
      (&FixPlanSheet.fix_plan_sheet/1)
      |> render_component(sheet: sheet, changed: %{"tray-count" => :skip})
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("#fix-plan-item-tray-count [data-qa=fix_plan_item_changed]") |> Floki.text() =~
             "Now Don't fix"

    assert Floki.find(doc, "#fix-plan-item-send-drops [data-qa=fix_plan_item_changed]") == []

    doc =
      (&FixPlanSheet.fix_plan_sheet/1)
      |> render_component(sheet: sheet, changed: %{"tray-count" => :new_issue})
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("#fix-plan-item-tray-count [data-qa=fix_plan_item_changed]") |> Floki.text() =~
             "Now New issue"
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

  test "every line of its text draws a + on the next round's plan only while commenting is offered", %{sheet: sheet} do
    offered =
      (&FixPlanSheet.fix_plan_sheet/1)
      |> render_component(sheet: sheet, offered: true, target: "#review-stage")
      |> Floki.parse_fragment!()

    adds = offered |> Floki.attribute("[data-qa='line_comment_add']", "phx-value-key") |> MapSet.new()
    drawn = for line <- build_fix_plan_lines(sheet).lines, into: MapSet.new(), do: line.key

    assert adds == drawn
    assert offered |> Floki.attribute("[data-qa='line_comment_add']", "phx-value-doc") |> Enum.uniq() == ["fix_plan"]
    assert offered |> Floki.attribute("[data-qa='line_comment_add']", "phx-target") |> Enum.uniq() == ["#review-stage"]
    assert "Comment on File 2" in Floki.attribute(offered, "[data-qa='line_comment_add']", "aria-label")

    quiet = (&FixPlanSheet.fix_plan_sheet/1) |> render_component(sheet: sheet) |> Floki.parse_fragment!()

    assert Floki.find(quiet, "[data-qa='line_comment_add']") == []
    assert quiet |> Floki.find("[data-qa='commentable_line']") |> length() == MapSet.size(drawn)
  end

  test "a comment is drawn under its line, the box opens under the line it is for, and a changed one sits at the top",
       %{sheet: sheet} do
    %{cards: [_first, %{line: path_line} | _cards], verification_lines: [verification]} =
      build_fix_plan_lines(sheet)

    placed = %PlanComment{
      id: "pcm_placed",
      target: :fix_plan,
      element_kind: :file,
      element_label: "File 2",
      element_text: "lib/tray.ex",
      body: "Count them in the tray."
    }

    lifted = %PlanComment{
      id: "pcm_lifted",
      target: :fix_plan,
      element_kind: :paragraph,
      element_label: "Summary, paragraph 1",
      element_text: "Three changes.",
      body: "Which three?"
    }

    doc =
      (&FixPlanSheet.fix_plan_sheet/1)
      |> render_component(
        sheet: sheet,
        offered: true,
        placed: %{path_line.key => [{placed, 1}]},
        lifted: [{lifted, 2}],
        draft: %{doc: :fix_plan, key: verification.key, label: verification.label, body: "Run it twice."}
      )
      |> Floki.parse_fragment!()

    [under] =
      doc
      |> Floki.find("[data-qa='commentable_line']")
      |> Enum.filter(&(Floki.find(&1, "#line-fix_plan-#{path_line.key}") != []))

    assert under |> Floki.find("[data-qa='line_comments'] #document-comment-pcm_placed") |> Floki.text() =~
             "Count them in the tray."

    assert under |> Floki.find("[data-qa='document_comment_number']") |> Floki.text() =~ "1"
    assert [_placed] = Floki.find(doc, "#document-comment-pcm_placed")

    assert [_box] = Floki.find(doc, "#document-comment-form-#{verification.key}")

    [changed] = Floki.find(doc, "#fix-plan-changed-comments [data-lifted='true']")
    assert Floki.text(changed) =~ "Summary, paragraph 1 as you commented on it"
    assert Floki.text(changed) =~ "Three changes."
    assert [_lifted] = Floki.find(doc, "#document-comment-pcm_lifted")

    quiet = (&FixPlanSheet.fix_plan_sheet/1) |> render_component(sheet: sheet) |> Floki.parse_fragment!()
    assert Floki.find(quiet, "#fix-plan-changed-comments") == []
    assert Floki.find(quiet, "[data-qa='line_comments']") == []
  end
end
