defmodule RailWeb.Components.StageStepperTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Runs.Schemas.Run
  alias RailWeb.Components.StageStepper

  test "renders all canonical stages when task uses design" do
    task = %{stage: :product}
    html = render_component(&StageStepper.stage_stepper/1, task: task)

    assert html =~ "id=\"stage-stepper\""
    assert html =~ "id=\"stage-chip-product\""
    assert html =~ "id=\"stage-chip-design\""
    assert html =~ "id=\"stage-chip-architect\""
    assert html =~ "id=\"stage-chip-engineer\""
    assert html =~ "id=\"stage-chip-review\""
    assert html =~ "id=\"stage-chip-qa\""
    assert html =~ "id=\"stage-chip-qa_lead\""
    assert html =~ "id=\"stage-chip-demo\""
    assert html =~ "id=\"stage-chip-ready_to_merge\""
    refute html =~ "id=\"stage-chip-merged\""
  end

  test "skips design stage when task does not use design" do
    task = %{stage: :architect}
    html = render_component(&StageStepper.stage_stepper/1, task: task)

    assert html =~ "id=\"stage-chip-product\""
    assert html =~ "id=\"stage-chip-architect\""
    refute html =~ "id=\"stage-chip-design\""
  end

  test "shows checkmark for done stages and current icon for current stage" do
    task = %{stage: :engineer}
    html = render_component(&StageStepper.stage_stepper/1, task: task)

    # Product is done: check_circle
    assert html =~ ~s(data-stage="product" data-current="false" data-done="true")

    # Engineer is current: play_circle_outline
    assert html =~ ~s(data-stage="engineer" data-current="true" data-done="false")

    # Review is future: radio_button_unchecked
    assert html =~ ~s(data-stage="review" data-current="false" data-done="false")
  end

  test "delegated CoreComponents.stage_stepper renders properly" do
    task = %{stage: :demo}
    html = render_component(&RailWeb.CoreComponents.stage_stepper/1, task: task)

    assert html =~ "id=\"stage-stepper\""
    assert html =~ ~s(data-stage="demo" data-current="true")
  end

  test "renders an amber chip when the current stage is waiting on a human" do
    task = %{stage: :engineer, run: %Run{status: :finished, stage_outcome: :done}}
    html = render_component(&StageStepper.stage_stepper/1, task: task)

    assert html =~ "border-amber-500"
  end

  test "handles string and invalid stage values gracefully" do
    task_string = %{stage: "qa"}
    html_string = render_component(&StageStepper.stage_stepper/1, task: task_string)
    assert html_string =~ ~s(data-stage="qa" data-current="true")

    task_invalid = %{stage: "unknown_stage_xyz"}
    html_invalid = render_component(&StageStepper.stage_stepper/1, task: task_invalid)
    assert html_invalid =~ "id=\"stage-stepper\""

    task_nil = %{}
    html_nil = render_component(&StageStepper.stage_stepper/1, task: task_nil)
    assert html_nil =~ "id=\"stage-stepper\""
  end
end
