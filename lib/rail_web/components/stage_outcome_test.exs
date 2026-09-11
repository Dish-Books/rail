defmodule RailWeb.Components.StageOutcomeTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.StageOutcome

  test "renders nothing when role_run is nil" do
    task = %{stage: :engineer, stage_state: :running}
    html = render_component(&StageOutcome.stage_outcome/1, task: task, role_run: nil)
    refute html =~ "id=\"stage-outcome\""
  end

  test "renders nothing when output and error are empty" do
    task = %{stage: :engineer, stage_state: :running}
    role_run = %{output: "   ", error: "   "}
    html = render_component(&StageOutcome.stage_outcome/1, task: task, role_run: role_run)
    refute html =~ "id=\"stage-outcome\""
  end

  test "renders Failure heading and error box when stage_state is failed and error present" do
    task = %{stage: :engineer, stage_state: :failed}
    role_run = %{role_id: "engineer", error: "mix test failed with 2 errors", output: nil}

    html = render_component(&StageOutcome.stage_outcome/1, task: task, role_run: role_run)

    assert html =~ "id=\"stage-outcome\""
    assert html =~ "id=\"stage-failure-heading\""
    assert html =~ "Engineer Failure"
    assert html =~ "id=\"stage-failure-box\""
    assert html =~ "mix test failed with 2 errors"
    refute html =~ "id=\"stage-outcome-heading\""
  end

  test "does not render failure if stage_state is not failed even if error is in role_run" do
    task = %{stage: :engineer, stage_state: :running}
    role_run = %{role_id: "engineer", error: "old error", output: "Current output"}

    html = render_component(&StageOutcome.stage_outcome/1, task: task, role_run: role_run)

    refute html =~ "id=\"stage-failure-heading\""
    assert html =~ "id=\"stage-outcome-heading\""
    assert html =~ "Engineer Outcome"
    assert html =~ "Current output"
  end

  test "renders Outcome heading and markdown output" do
    task = %{stage: :engineer, stage_state: :awaiting_approval}
    role_run = %{role_id: "engineer", output: "## Implementation complete\n\nAll tests pass."}

    html = render_component(&StageOutcome.stage_outcome/1, task: task, role_run: role_run)

    assert html =~ "id=\"stage-outcome-heading\""
    assert html =~ "Engineer Outcome"
    assert html =~ "Implementation complete"
    assert html =~ "All tests pass."
  end

  test "uses explicit role_name when provided" do
    task = %{stage: :engineer, stage_state: :failed}
    role_run = %{error: "some error"}

    html = render_component(&StageOutcome.stage_outcome/1, task: task, role_run: role_run, role_name: "Code Expert")

    assert html =~ "Code Expert Failure"
  end

  test "delegated CoreComponents.stage_outcome renders properly" do
    task = %{stage: :engineer, stage_state: :awaiting_approval}
    role_run = %{role_id: "engineer", output: "Done"}

    html = render_component(&RailWeb.CoreComponents.stage_outcome/1, task: task, role_run: role_run)

    assert html =~ "Engineer Outcome"
  end

  test "format_role_id formats various role identifiers" do
    assert StageOutcome.format_role_id(nil) == "Stage"
    assert StageOutcome.format_role_id(:product) == "Product"
    assert StageOutcome.format_role_id("design") == "Designer"
    assert StageOutcome.format_role_id("designer") == "Designer"
    assert StageOutcome.format_role_id("review") == "Reviewer"
    assert StageOutcome.format_role_id("reviewer") == "Reviewer"
    assert StageOutcome.format_role_id("qa_lead") == "QA Lead"
    assert StageOutcome.format_role_id(:qa_lead) == "QA Lead"
    assert StageOutcome.format_role_id("custom_role_check") == "Custom Role Check"
    assert StageOutcome.format_role_id(123) == "123"
  end

  test "resolves role name and handles string map keys" do
    task_with_str_keys = %{"stage" => "review", "stage_state" => "failed", "current_role_id" => "reviewer"}
    role_run = %{"output" => "All checked"}

    html = render_component(&StageOutcome.stage_outcome/1, task: task_with_str_keys, role_run: role_run)
    assert html =~ "Reviewer Outcome"
    assert html =~ "All checked"

    # Task without stage or role falls back to Stage
    empty_task = %{}
    role_run2 = %{output: "Empty task output"}
    html2 = render_component(&StageOutcome.stage_outcome/1, task: empty_task, role_run: role_run2)
    assert html2 =~ "Stage Outcome"

    # Nil task falls back safely
    html_nil_task = render_component(&StageOutcome.stage_outcome/1, task: nil, role_run: role_run2)
    assert html_nil_task =~ "Stage Outcome"
  end
end
