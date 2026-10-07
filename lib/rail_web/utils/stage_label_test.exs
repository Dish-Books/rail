defmodule RailWeb.Utils.StageLabelTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.StageLabel

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  test "a child of a split with no run reads what its earlier siblings hold it on" do
    siblings = [
      %Task{split_position: 1, issue: %Issue{identifier: "SPL-1", state: :in_progress}},
      %Task{split_position: 2, issue: %Issue{identifier: "SPL-2", state: :canceled}},
      %Task{split_position: 3, issue: %Issue{identifier: "SPL-3", state: :done, completed_at: ~U[2026-10-07 10:00:00Z]}}
    ]

    child = &%Task{stage: :engineer, runs: [], builds_on: &1, parent_task: %Task{children: siblings}}

    assert stage_label(child.([1, 3]), nil) == "Waiting on SPL-1"
    assert stage_label(child.([1, 2]), nil) == "Blocked by SPL-2"
    assert stage_label(child.([3]), nil) == "Queued for Engineer"
  end

  test "no task at all is something waiting on you" do
    assert stage_label(nil, nil) == "Waiting on you"
  end

  test "a merged task says it merged, whatever its last run did" do
    assert stage_label(%Task{stage: :merged}, nil) == "Merged"
    assert stage_label(%Task{stage: :merged}, %Run{status: :finished, stage_outcome: :done}) == "Merged"
    assert stage_label(%Task{stage: :split}, %Run{status: :finished, stage_outcome: :done}) == "Plan approved"
  end

  test "a stage that has not started is queued for it" do
    assert stage_label(%Task{stage: :plan}, nil) == "Queued for Plan"
  end

  test "a working stage says so" do
    assert stage_label(%Task{stage: :plan}, %Run{status: :running}) == "Plan running"
    assert stage_label(%Task{stage: :engineer}, %Run{status: :waiting_for_resources}) == "Engineer waiting for resources"
    assert stage_label(%Task{stage: :engineer}, %Run{status: :waiting_for_usage}) == "Engineer waiting for usage"
  end

  test "a stage parked on a question asks for the answer" do
    assert stage_label(%Task{stage: :plan}, %Run{status: :blocked_on_input}) == "Plan needs an answer"
  end

  test "a stage that hit an error says it failed" do
    assert stage_label(%Task{stage: :plan}, %Run{status: :finished, error: "boom"}) == "Plan failed"
  end

  test "a stage that stopped without saying anything reads as stopped" do
    assert stage_label(%Task{stage: :plan}, %Run{status: :finished}) == "Plan stopped"
  end

  test "a stage that concluded says what the human has to decide" do
    done = %Run{status: :finished, stage_outcome: :done}
    scratch = Path.join(System.tmp_dir!(), "stage_label_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)

    assert stage_label(%Task{stage: :plan, scratch_path: scratch}, done) == "Review the plan"
    assert stage_label(%Task{stage: :engineer}, done) == "Review the diff"
    assert stage_label(%Task{stage: :review}, done) == "Review the findings"
    assert stage_label(%Task{stage: :qa}, done) == "Review the QA report"
    assert stage_label(%Task{stage: :demo}, done) == "Watch the demo"
    assert approval_label(%Task{stage: :merged}) == "Waiting on you"
  end

  test "a Plan run done with options and no pick asks for the pick, and once picked for the review" do
    done = %Run{status: :finished, stage_outcome: :done}
    scratch = Path.join(System.tmp_dir!(), "stage_label_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    task = %Task{stage: :plan, scratch_path: scratch}

    options = for key <- ["a", "b", "c"], do: %{"key" => key, "title" => String.upcase(key)}
    File.mkdir_p!(Path.join(scratch, "design"))
    File.write!(Path.join(scratch, "design/manifest.json"), Jason.encode!(%{"options" => options}))

    assert waiting_on_pick?(task)
    assert stage_label(task, done) == "Pick a design"

    File.write!(Path.join(scratch, "design/picked"), "b")

    refute waiting_on_pick?(task)
    assert stage_label(task, done) == "Review the plan"
  end
end
