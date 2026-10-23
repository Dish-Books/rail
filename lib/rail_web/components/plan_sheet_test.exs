defmodule RailWeb.Components.PlanSheetTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import RailTest.Helpers
  import RailWeb.Helpers, only: [build_plan_sheet: 1, build_plan_sheet: 2]

  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Projects.Schemas.Project
  alias RailWeb.Components.PlanSheet

  setup_all do
    criteria = [
      %{number: 1, html: "<p>A task sent back lands at Architect.</p>"},
      %{number: 2, html: "<p>The note reaches the brief.</p>"},
      %{number: 3, html: "<p>Review shows Send back.</p>"}
    ]

    %{
      sheet: build_plan_sheet(sheet_plan(), [1, 2, 3]),
      criteria: criteria,
      project: %Project{github_repo: "example/rail", default_branch: "main"}
    }
  end

  test "lays a plan out in one column with no diagrams and no In this plan box", %{sheet: sheet} do
    html = (&PlanSheet.plan_sheet/1) |> render_component(sheet: sheet) |> Floki.parse_fragment!()

    assert [class] = Floki.attribute(html, "#plan-sheet", "class")
    assert class =~ "max-w-[1120px]"

    assert Floki.text(Floki.find(html, "#plan-approach")) =~ "Sending a task back is a stage move"
    assert Floki.find(html, "figure") == []
    assert Floki.find(html, "#plan-summary") == []
    refute Floki.text(html) =~ "In this plan"

    assert [change] = Floki.find(html, "#plan-data-changes [data-qa='plan_data_change']")
    assert Floki.text(change) =~ ~r/New column\s+tasks.sent_back_note\s+text, null until a task is sent back./

    assert [decision, ruled_out, assumption] = Floki.find(html, "#plan-decisions [data-qa='plan_decision']")
    assert Floki.text(decision) =~ ~r/Decision\s+the note is kept on the task/
    refute Floki.text(decision) =~ "Decision:"
    assert Floki.text(ruled_out) =~ ~r/Ruled out\s+a table of send-backs/
    assert Floki.text(assumption) =~ ~r/Assumption\s+the note is required/

    assert Floki.text(Floki.find(html, "#plan-verification")) =~ "A task sent back from Review is at Architect"
  end

  test "a group is a block headed by its name, directory and file count, drawn open and left to the browser", %{
    sheet: sheet
  } do
    html = (&PlanSheet.plan_sheet/1) |> render_component(sheet: sheet) |> Floki.parse_fragment!()

    assert ["plan-group-pipeline", "plan-group-web", "plan-group-migrations"] =
             Floki.attribute(html, "details[data-qa='plan_group']", "id")

    [pipeline] = Floki.find(html, "#plan-group-pipeline")
    assert Floki.attribute(pipeline, "open") == ["open"]
    assert [mounted] = Floki.attribute(pipeline, "phx-mounted")
    assert mounted =~ "ignore_attrs"
    assert Floki.attribute(pipeline, "summary", "phx-click") == []

    assert Floki.text(Floki.find(pipeline, "summary")) =~ ~r/pipeline\s+lib\/rail\/pipeline\s+3\s+files/
    assert Floki.text(Floki.find(html, "#plan-group-web summary")) =~ ~r/web\s+lib\/rail_web\s+1\s+file\b/
  end

  test "two children's parts name the same group apart, so a fold stays with its own part", %{sheet: sheet} do
    ids =
      for part <- [1, 2] do
        (&PlanSheet.plan_sheet/1)
        |> render_component(sheet: sheet, doc: :split_part, part: part)
        |> Floki.parse_fragment!()
        |> Floki.attribute("details[data-qa='plan_group']", "id")
        |> hd()
      end

    assert ids == ["split-part-1-group-pipeline", "split-part-2-group-pipeline"]
  end

  test "a card shows its path, its prose, then its signatures, and a Deleted badge only when deleted", %{sheet: sheet} do
    html = (&PlanSheet.plan_sheet/1) |> render_component(sheet: sheet) |> Floki.parse_fragment!()

    [card] = Floki.find(html, "#plan-card-1")
    text = Floki.text(card)
    assert text =~ "lib/rail/pipeline/actions/send_back_to_architect.ex"

    assert text =~
             ~r/Refuses unless the task is at :review and idle\..*def send_back_to_architect\(%Run\{\} = run, note\)/s

    assert Floki.find(card, "[data-qa='plan_card_deleted']") == []

    assert Floki.text(Floki.find(html, "#plan-card-3 [data-qa='plan_card_deleted']")) =~ "Deleted"
    assert Floki.text(Floki.find(html, "#plan-card-3")) =~ "lib/rail/pipeline/actions/old_send_back.ex"
    assert Floki.find(html, "#plan-card-2 [data-qa='plan_card_sketch']") == []
  end

  test "a path on the default branch reads Changed and links to it on GitHub in a new tab, one off it reads New", %{
    sheet: sheet,
    project: project
  } do
    on_main = MapSet.new(["lib/rail/pipeline.ex", "lib/rail/pipeline/actions/old_send_back.ex"])

    html =
      (&PlanSheet.plan_sheet/1)
      |> render_component(sheet: sheet, default_paths: on_main, project: project)
      |> Floki.parse_fragment!()

    assert Floki.text(Floki.find(html, "#plan-card-1 [data-qa='plan_card_new']")) =~ "New"
    assert Floki.find(html, "#plan-card-1 [data-qa='plan_card_link']") == []
    assert Floki.text(Floki.find(html, "#plan-card-1")) =~ "lib/rail/pipeline/actions/send_back_to_architect.ex"

    assert Floki.text(Floki.find(html, "#plan-card-2 [data-qa='plan_card_changed']")) =~ "Changed"
    assert [link] = Floki.find(html, "#plan-card-2 a[data-qa='plan_card_link']")
    assert Floki.attribute(link, "href") == ["https://github.com/example/rail/blob/main/lib/rail/pipeline.ex"]
    assert Floki.attribute(link, "target") == ["_blank"]
    assert Floki.attribute(link, "rel") == ["noopener noreferrer"]
    assert Floki.attribute(link, "title") == ["Open lib/rail/pipeline.ex on main in GitHub (new tab)"]
    assert Floki.text(link) =~ "lib/rail/pipeline.ex"
    assert Floki.find(link, "[class*='pi-arrow-up-right-bold']") != []

    assert html |> Floki.find("#plan-changes h3 + span") |> Floki.text() =~ "Changed files link to main on GitHub."
  end

  test "a deleted card reads Deleted, and links to GitHub only while the default branch still has it", %{
    sheet: sheet,
    project: project
  } do
    render = fn paths ->
      (&PlanSheet.plan_sheet/1)
      |> render_component(sheet: sheet, default_paths: paths, project: project)
      |> Floki.parse_fragment!()
      |> Floki.find("#plan-card-3")
    end

    on_main = render.(MapSet.new(["lib/rail/pipeline/actions/old_send_back.ex"]))
    assert Floki.text(Floki.find(on_main, "[data-qa='plan_card_deleted']")) =~ "Deleted"
    assert Floki.find(on_main, "[data-qa='plan_card_new'], [data-qa='plan_card_changed']") == []

    assert Floki.attribute(on_main, "a[data-qa='plan_card_link']", "href") == [
             "https://github.com/example/rail/blob/main/lib/rail/pipeline/actions/old_send_back.ex"
           ]

    off_main = render.(MapSet.new())
    assert Floki.text(Floki.find(off_main, "[data-qa='plan_card_deleted']")) =~ "Deleted"
    assert Floki.find(off_main, "[data-qa='plan_card_link']") == []
  end

  test "each group header counts its new, changed and deleted files in place of its file count", %{
    sheet: sheet,
    project: project
  } do
    on_main = MapSet.new(["lib/rail/pipeline.ex", "lib/rail_web/live/review_stage.ex"])

    html =
      (&PlanSheet.plan_sheet/1)
      |> render_component(sheet: sheet, default_paths: on_main, project: project)
      |> Floki.parse_fragment!()

    counts = for group <- Floki.find(html, "[data-qa='plan_group_count']"), do: String.trim(Floki.text(group))
    assert counts == ["1 new · 1 changed · 1 deleted", "1 changed", "1 new"]
  end

  test "without the default branch's paths a card reads neither New nor Changed and links nowhere", %{sheet: sheet} do
    html = (&PlanSheet.plan_sheet/1) |> render_component(sheet: sheet) |> Floki.parse_fragment!()

    assert Floki.find(html, "[data-qa='plan_card_new'], [data-qa='plan_card_changed']") == []
    assert Floki.find(html, "[data-qa='plan_card_link']") == []
    assert [_deleted] = Floki.find(html, "[data-qa='plan_card_deleted']")

    counts = for group <- Floki.find(html, "[data-qa='plan_group_count']"), do: String.trim(Floki.text(group))
    assert counts == ["3 files", "1 file", "1 file"]
    refute Floki.text(Floki.find(html, "#plan-changes")) =~ "GitHub"
  end

  test "a path holding a # or a space links with them escaped, so GitHub opens the whole path", %{project: project} do
    plan =
      "## Implementation plan\n\n### Approach\n\nAll of it.\n\n### Decisions\n\n- Decision: one file.\n\n" <>
        "### Changes\n\n#### `docs/notes #1.md`\n\nRewrites it.\n\n### Acceptance criteria\n\n- 1: `docs/notes #1.md`\n\n" <>
        "### Verification\n\n- Reads well."

    html =
      (&PlanSheet.plan_sheet/1)
      |> render_component(
        sheet: build_plan_sheet(plan),
        default_paths: MapSet.new(["docs/notes #1.md"]),
        project: %{project | default_branch: "release/2026"}
      )
      |> Floki.parse_fragment!()

    assert Floki.attribute(html, "a[data-qa='plan_card_link']", "href") == [
             "https://github.com/example/rail/blob/release/2026/docs/notes%20%231.md"
           ]
  end

  test "a sketch is drawn closed unless one of its lines has the reader's comment", %{sheet: sheet} do
    html = (&PlanSheet.plan_sheet/1) |> render_component(sheet: sheet) |> Floki.parse_fragment!()

    [%{id: id, sketch: [_first, second, _end]}] = Enum.take(sheet.cards, 1)
    [sketch] = Floki.find(html, "#plan-sketch-#{id}")
    assert Floki.attribute(sketch, "open") == []
    assert Floki.text(Floki.find(sketch, "summary"), sep: " ") =~ ~r/Show code\s+Hide code/
    assert Floki.text(sketch) =~ "enter_stage(task, :architect, %{sent_back_note: note})"

    comment = %PlanComment{
      id: "pcm_s",
      target: :plan,
      element_kind: :code,
      element_label: second.label,
      element_text: second.text,
      body: "Through EnterStage?"
    }

    html =
      (&PlanSheet.plan_sheet/1)
      |> render_component(sheet: sheet, placed: %{second.key => [{comment, 1}]})
      |> Floki.parse_fragment!()

    assert Floki.attribute(html, "#plan-sketch-#{id}", "open") == ["open"]
    assert Floki.text(Floki.find(html, "#plan-sketch-#{id}")) =~ "Through EnterStage?"
  end

  test "a sketch keeps its id when a revision adds a card above its own", %{sheet: sheet} do
    html = (&PlanSheet.plan_sheet/1) |> render_component(sheet: sheet) |> Floki.parse_fragment!()
    assert [id] = Floki.attribute(html, "#plan-card-1 [data-qa='plan_card_sketch']", "id")

    plan =
      String.replace(
        sheet_plan(),
        "#### `lib/rail/pipeline/actions/send_back_to_architect.ex`",
        "#### `lib/rail/pipeline/actions/enter_stage.ex`\n\nTakes the note.\n\n" <>
          "#### `lib/rail/pipeline/actions/send_back_to_architect.ex`"
      )

    html =
      (&PlanSheet.plan_sheet/1)
      |> render_component(sheet: build_plan_sheet(plan, [1, 2, 3]))
      |> Floki.parse_fragment!()

    assert Floki.text(Floki.find(html, "#plan-card-2")) =~ "send_back_to_architect.ex"
    assert [^id] = Floki.attribute(html, "#plan-card-2 [data-qa='plan_card_sketch']", "id")
  end

  test "a criterion the plan names nothing for reads Not covered, and those around it keep their files and tests", %{
    sheet: sheet,
    criteria: criteria
  } do
    html =
      (&PlanSheet.plan_sheet/1)
      |> render_component(sheet: sheet, criteria: criteria)
      |> Floki.parse_fragment!()

    assert [first, second, third] = Floki.find(html, "#plan-criteria [data-qa='plan_criterion']")

    assert Floki.text(first, sep: " ") =~
             ~r/Covered:\s+A task sent back lands at Architect.\s+send_back_to_architect.ex\s+send_back_to_architect_test.exs/

    assert Floki.text(second, sep: " ") =~ ~r/Not covered:\s+The note reaches the brief.\s+Not covered/
    assert Floki.text(third, sep: " ") =~ ~r/Covered:\s+Review shows Send back.\s+review_stage.ex/
  end

  test "a bullet for a criterion the ticket lacks is not drawn, and without the ticket's words a row reads by number", %{
    sheet: sheet,
    criteria: criteria
  } do
    html =
      (&PlanSheet.plan_sheet/1)
      |> render_component(sheet: build_plan_sheet(sheet_plan(), [1]), criteria: Enum.take(criteria, 1))
      |> Floki.parse_fragment!()

    assert [only] = Floki.find(html, "[data-qa='plan_criterion']")
    assert Floki.text(only) =~ "A task sent back lands at Architect."

    html = (&PlanSheet.plan_sheet/1) |> render_component(sheet: sheet) |> Floki.parse_fragment!()

    assert [first, second, third] = Floki.find(html, "[data-qa='plan_criterion']")
    assert Floki.text(first, sep: " ") =~ ~r/\ACovered:\s+Criterion 1\s+send_back_to_architect.ex/
    assert Floki.text(second, sep: " ") =~ ~r/\ANot covered:\s+Criterion 2\s+Not covered/
    assert Floki.text(third, sep: " ") =~ ~r/\ACovered:\s+Criterion 3\s+review_stage.ex/

    plan = String.replace(sheet_plan(), ~r/### Acceptance criteria\n.*?### Verification/s, "### Verification")
    html = render_component(&PlanSheet.plan_sheet/1, sheet: build_plan_sheet(plan), criteria: criteria)
    refute html =~ "plan-criteria"
  end

  test "a Not covered row takes a comment, and a saved row naming no path reads Not covered", %{
    sheet: sheet,
    criteria: criteria
  } do
    html =
      (&PlanSheet.plan_sheet/1)
      |> render_component(sheet: sheet, criteria: criteria, offered: true)
      |> Floki.parse_fragment!()

    assert [_first, second, _third] = Floki.find(html, "#plan-criteria [data-qa='plan_criterion']")
    assert Floki.text(second, sep: " ") =~ ~r/Not covered:\s+The note reaches the brief.\s+Not covered/
    assert [_add] = Floki.find(html, "#plan-criteria button[aria-label='Comment on Criterion 2']")

    plan = String.replace(sheet_plan(), "- 3: `lib/rail_web", "- 2: handled by the existing flow\n- 3: `lib/rail_web")

    html =
      (&PlanSheet.plan_sheet/1)
      |> render_component(sheet: build_plan_sheet(plan, [1, 2, 3]), criteria: criteria)
      |> Floki.parse_fragment!()

    assert [_first, second, _third] = Floki.find(html, "#plan-criteria [data-qa='plan_criterion']")
    assert Floki.text(second, sep: " ") =~ ~r/Not covered:\s+The note reaches the brief.\s+Not covered/
  end

  test "every line of the sheet draws a + while commenting is offered, and the changed comments sit at the top", %{
    sheet: sheet
  } do
    lifted = %PlanComment{
      id: "pcm_l",
      target: :plan,
      element_kind: :paragraph,
      element_label: "Approach, paragraph 1",
      element_text: "As it read.",
      body: "Hm."
    }

    html =
      (&PlanSheet.plan_sheet/1)
      |> render_component(sheet: sheet, offered: true, changed: [{lifted, 1}])
      |> Floki.parse_fragment!()

    adds = html |> Floki.attribute("[data-qa='line_comment_add']", "phx-value-key") |> MapSet.new()

    assert MapSet.new(sheet.lines, & &1.key) == adds
    assert [_lifted] = Floki.find(html, "#plan-changed-comments [data-lifted='true']")

    quiet = (&PlanSheet.plan_sheet/1) |> render_component(sheet: sheet) |> Floki.parse_fragment!()
    assert Floki.find(quiet, "[data-qa='line_comment_add']") == []
  end

  test "a code block or a table in a section's prose draws as code and table lines that take comments" do
    plan =
      sheet_plan()
      |> String.replace(
        "the only thing that writes `task.stage`.",
        "the only thing that writes `task.stage`.\n\n```\nenter_stage(task, :architect)\n```"
      )
      |> String.replace(
        "with the note in its brief.",
        "with the note in its brief.\n\n| Stage | Then |\n|---|---|\n| Review | Architect |"
      )

    sheet = build_plan_sheet(plan)
    html = (&PlanSheet.plan_sheet/1) |> render_component(sheet: sheet, offered: true) |> Floki.parse_fragment!()

    assert Floki.text(Floki.find(html, "#plan-approach [data-kind='code']")) =~ "enter_stage(task, :architect)"
    assert [_header, _row] = Floki.find(html, "#plan-verification [data-kind='table_row']")
    assert html |> Floki.attribute("[data-qa='line_comment_add']", "phx-value-key") |> length() == length(sheet.lines)
  end
end
