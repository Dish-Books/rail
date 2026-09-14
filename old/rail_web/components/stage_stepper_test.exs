defmodule RailWeb.Components.StageStepperTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Runs.Schemas.Run
  alias RailWeb.Components.StageStepper

  test "renders all canonical stages" do
    task = %Task{stage: :product}
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

  test "shows checkmark for done stages and current icon for current stage" do
    task = %Task{stage: :engineer}
    html = render_component(&StageStepper.stage_stepper/1, task: task)

    # Product is done: check_circle
    assert html =~ ~s(data-stage="product" data-current="false" data-done="true")

    # Engineer is current: play_circle_outline
    assert html =~ ~s(data-stage="engineer" data-current="true" data-done="false")

    # Review is future: radio_button_unchecked
    assert html =~ ~s(data-stage="review" data-current="false" data-done="false")
  end

  test "delegated CoreComponents.stage_stepper renders properly" do
    task = %Task{stage: :demo}
    html = render_component(&RailWeb.CoreComponents.stage_stepper/1, task: task)

    assert html =~ "id=\"stage-stepper\""
    assert html =~ ~s(data-stage="demo" data-current="true")
  end

  test "renders an amber chip when the current stage is waiting on a human" do
    html =
      render_component(&StageStepper.stage_stepper/1,
        task: %Task{stage: :engineer},
        run: %Run{status: :finished, stage_outcome: :done}
      )

    assert html =~ "border-amber-500"
  end
end
