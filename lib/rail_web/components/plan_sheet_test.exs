defmodule RailWeb.Components.PlanSheetTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import RailTest.Helpers
  import RailWeb.Utils.BuildPlanSheet

  alias RailWeb.Components.PlanSheet

  setup_all do
    %{views: %{change: :diagram, call_flow: :diagram}}
  end

  test "lays out a full plan with its summary, diagrams, files and modules", %{views: views} do
    html =
      (&PlanSheet.plan_sheet/1)
      |> render_component(sheet: build_plan_sheet(sheet_plan()), diagram_views: views, event: "diagram_view")
      |> Floki.parse_fragment!()

    summary = Floki.find(html, "#plan-summary")
    assert Floki.text(summary) =~ ~r/2\s+files\s+·\s+2\s+modules\s+·\s+2\s+diagrams/
    assert Floki.text(summary) =~ "Change diagram and call flow"
    assert Floki.text(summary) =~ "Every module in Program design is in File-level changes"
    refute Floki.text(summary) =~ "not in File-level changes"

    assert Floki.text(Floki.find(html, "#plan-approach")) =~ "Sending a task back is a stage move"
    assert length(Floki.find(html, "figure[phx-hook='PlanDiagram']")) == 2
    assert Floki.find(html, "#plan-no-diagrams") == []

    assert Floki.attribute(html, "#plan-files", "phx-hook") == ["PlanLinks"]

    assert Floki.attribute(html, "#plan-file-1", "data-plan-file") == [
             "lib/rail/pipeline/actions/send_back_to_architect.ex"
           ]

    assert Floki.text(Floki.find(html, "#plan-file-2")) =~ "Delegates send_back_to_architect/2"

    assert [action, context] = Floki.find(html, "[data-qa='plan_module']")
    assert Floki.attribute(action, "data-plan-file") == ["lib/rail/pipeline/actions/send_back_to_architect.ex"]
    assert Floki.text(action) =~ "Rail.Pipeline.Actions.SendBackToArchitect"
    assert Floki.text(Floki.find(action, "[data-qa='plan_module_new']")) =~ "new"
    assert Floki.attribute(action, "a", "href") == ["#plan-file-1"]
    assert Floki.text(Floki.find(action, "pre")) =~ "def send_back_to_architect(%Run{} = run, note)"
    assert Floki.find(context, "[data-qa='plan_module_new']") == []
    assert Floki.attribute(context, "a", "href") == ["#plan-file-2"]

    assert Floki.text(Floki.find(html, "#plan-verification")) =~ "pins the move to :architect"
    assert Floki.text(Floki.find(html, "#plan-assumptions")) =~ "The note is required"
  end

  test "a module missing from File-level changes is flagged on its card and in the summary", %{views: views} do
    plan =
      String.replace(sheet_plan(), "### Verification", """
      #### `Rail.Pipeline.Actions.EnterStage`

      `lib/rail/pipeline/actions/enter_stage.ex`

      ### Verification
      """)

    html =
      (&PlanSheet.plan_sheet/1)
      |> render_component(sheet: build_plan_sheet(plan), diagram_views: views, event: "diagram_view")
      |> Floki.parse_fragment!()

    assert Floki.text(Floki.find(html, "#plan-summary")) =~ "1 module in Program design is not in File-level changes"
    refute Floki.text(Floki.find(html, "#plan-summary")) =~ "Every module"

    assert [_action, _context, unlisted] = Floki.find(html, "[data-qa='plan_module']")
    assert Floki.text(unlisted) =~ "lib/rail/pipeline/actions/enter_stage.ex"
    assert Floki.text(unlisted) =~ "· not in File-level changes"
    assert Floki.find(unlisted, "a") == []
    assert [class] = Floki.attribute(unlisted, "class")
    assert class =~ "border-amber"
  end

  test "more than one unlisted module is counted as such", %{views: views} do
    plan =
      String.replace(
        sheet_plan(),
        ["`lib/rail/pipeline.ex`\n\n```elixir", "`lib/rail/pipeline/actions/send_back_to_architect.ex`\n\n```elixir"],
        "```elixir"
      )

    html =
      render_component(&PlanSheet.plan_sheet/1,
        sheet: build_plan_sheet(plan),
        diagram_views: views,
        event: "diagram_view"
      )

    assert html =~ "2 modules in Program design are not in File-level changes"
    assert html =~ "not in File-level changes"
  end

  test "a plan with no diagrams says why in one line, with no empty frames", %{views: views} do
    plan = """
    ## Implementation plan

    ### Approach

    The missing-worktree case in `Rail.Pipeline.Actions.CleanupTask` already returns `:ok`.

    No diagrams: this plan only adds tests, so no application code or call path changes.

    ### File-level changes

    - `lib/rail/pipeline/actions/cleanup_task_test.exs`: adds a case for a task whose worktree was already deleted.
    """

    html =
      (&PlanSheet.plan_sheet/1)
      |> render_component(sheet: build_plan_sheet(plan), diagram_views: views, event: "diagram_view")
      |> Floki.parse_fragment!()

    assert Floki.text(Floki.find(html, "#plan-no-diagrams")) =~
             "No diagrams: this plan only adds tests, so no application code or call path changes."

    assert Floki.find(html, "figure") == []
    summary = Floki.text(Floki.find(html, "#plan-summary"))
    assert summary =~ ~r/1\s+file\s+·\s+0\s+modules\s+·\s+0\s+diagrams/
    assert summary =~ "No diagrams, as the plan explains"
    assert summary =~ "No program design: no application code changes"
    refute summary =~ "Change diagram and call flow"
    assert Floki.find(html, "[data-qa='plan_module']") == []
    assert Floki.find(html, "#plan-verification") == []
    assert Floki.find(html, "#plan-assumptions") == []
  end

  test "a section the sheet has no place for still renders, under its own title", %{views: views} do
    plan =
      sheet_plan()
      |> String.replace("### Approach", "A note before the plan.\n\n### Approach")
      |> String.replace("### Assumptions", "### Rollout\n\nShip it behind nothing.\n\n### Assumptions")

    html =
      (&PlanSheet.plan_sheet/1)
      |> render_component(sheet: build_plan_sheet(plan), diagram_views: views, event: "diagram_view")
      |> Floki.parse_fragment!()

    assert [preamble, rollout] = Floki.find(html, "[data-qa='plan_section']")
    assert Floki.find(preamble, "h3") == []
    assert Floki.text(preamble) =~ "A note before the plan."
    assert Floki.text(Floki.find(rollout, "h3")) =~ "Rollout"
    assert Floki.text(rollout) =~ "Ship it behind nothing."
  end

  test "each diagram shows the view it was given", %{views: views} do
    html =
      (&PlanSheet.plan_sheet/1)
      |> render_component(
        sheet: build_plan_sheet(sheet_plan()),
        diagram_views: %{views | call_flow: :source},
        event: "diagram_view",
        target: "#architect-stage"
      )
      |> Floki.parse_fragment!()

    assert Floki.attribute(html, "button[phx-value-view='change:diagram']", "aria-pressed") == ["true"]
    assert Floki.attribute(html, "button[phx-value-view='call_flow:source']", "aria-pressed") == ["true"]
    assert Floki.attribute(html, "button[phx-value-view='call_flow:source']", "phx-target") == ["#architect-stage"]
  end
end
