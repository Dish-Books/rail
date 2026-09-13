defmodule RailWeb.Components.StageLabelTest do
  use ExUnit.Case, async: true

  import RailWeb.Components.StageLabel

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Runs.Schemas.Run

  test "no task at all is something waiting on you" do
    assert stage_label(nil, nil) == "Waiting on you"
  end

  test "a stage that has not started is queued for it" do
    assert stage_label(%Task{stage: :review}, nil) == "Queued for Review"
  end

  test "a stage whose branch cannot merge needs a rebase before anything else" do
    task = %Task{stage: :review, mergeability: :conflicting}

    assert stage_label(task, nil) == "Conflicts - needs a rebase"
    assert stage_label(task, %Run{status: :finished, stage_outcome: :done}) == "Conflicts - needs a rebase"
  end

  test "a working stage says so" do
    assert stage_label(%Task{stage: :review}, %Run{status: :running}) == "Review running"
  end

  test "a stage parked on a question asks for the answer" do
    assert stage_label(%Task{stage: :qa}, %Run{status: :blocked_on_input}) == "QA needs an answer"
  end

  test "a stage that hit an error says it failed" do
    assert stage_label(%Task{stage: :demo}, %Run{status: :finished, error: "boom"}) == "Demo failed"
  end

  test "a stage that stopped without saying anything reads as stopped" do
    assert stage_label(%Task{stage: :engineer}, %Run{status: :finished}) == "Engineer stopped"
  end

  test "a stage that concluded says what the human has to decide" do
    done = %Run{status: :finished, stage_outcome: :done}

    assert stage_label(%Task{stage: :product}, done) == "Review the ticket"
    assert stage_label(%Task{stage: :design}, done) == "Review the design"
    assert stage_label(%Task{stage: :architect}, done) == "Review the plan"
    assert stage_label(%Task{stage: :engineer}, done) == "Ready to send to review"
    assert stage_label(%Task{stage: :review}, done) == "Review needs your call"
    assert stage_label(%Task{stage: :qa}, done) == "QA needs your call"
    assert stage_label(%Task{stage: :qa_lead}, done) == "QA needs your call"
    assert stage_label(%Task{stage: :demo}, done) == "Review the demo"
    assert stage_label(%Task{stage: :ready_to_merge}, done) == "Ready to merge"
    assert stage_label(%Task{stage: :debugger}, done) == "Waiting on you"
  end

  test "a rebase reads as a rebase wherever the task is parked" do
    task = %Task{stage: :review, is_rebasing: true}

    assert stage_label(task, nil) == "Queued to rebase"
    assert stage_label(task, %Run{status: :running}) == "Rebasing the branch"
    assert stage_label(task, %Run{status: :blocked_on_input}) == "Rebase needs an answer"
    assert stage_label(task, %Run{status: :finished, error: "boom"}) == "Rebase failed"
    assert stage_label(task, %Run{status: :finished}) == "Rebase stopped"
    assert stage_label(task, %Run{status: :finished, stage_outcome: :done}) == "Queued to rebase"
  end

  test "rework is counted once the engineer has had the change" do
    reworked = %Task{stage: :review, rework_cycles: 2, rework_budget_base: 1}

    assert stage_label(reworked, %Run{status: :running}) == "Review running · rework 2 of 6"
    assert stage_label(%{reworked | stage: :product}, %Run{status: :running}) == "Product running"
  end
end
