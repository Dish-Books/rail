defmodule RailWeb.Utils.StageLabelTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.StageLabel

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  test "no task at all is something waiting on you" do
    assert stage_label(nil, nil) == "Waiting on you"
  end

  test "a stage that has not started is queued for it" do
    assert stage_label(%Task{stage: :product}, nil) == "Queued for Product"
  end

  test "a working stage says so" do
    assert stage_label(%Task{stage: :product}, %Run{status: :running}) == "Product running"
  end

  test "a stage parked on a question asks for the answer" do
    assert stage_label(%Task{stage: :product}, %Run{status: :blocked_on_input}) == "Product needs an answer"
  end

  test "a stage that hit an error says it failed" do
    assert stage_label(%Task{stage: :product}, %Run{status: :finished, error: "boom"}) == "Product failed"
  end

  test "a stage that stopped without saying anything reads as stopped" do
    assert stage_label(%Task{stage: :product}, %Run{status: :finished}) == "Product stopped"
  end

  test "a stage that concluded says what the human has to decide" do
    done = %Run{status: :finished, stage_outcome: :done}

    assert stage_label(%Task{stage: :product}, done) == "Review the ticket"
    assert stage_label(%Task{stage: :design}, done) == "Review the designs"
    assert stage_label(%Task{stage: :architect}, done) == "Review the plan"
    assert stage_label(%Task{stage: :engineer}, done) == "Review the diff"
    assert stage_label(%Task{stage: :review}, done) == "Review the findings"
    assert stage_label(%Task{stage: :qa}, done) == "Waiting on you"
  end
end
