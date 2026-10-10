defmodule RailWeb.Utils.StageLabelTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.StageLabel

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role

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
    assert stage_label(child.([1, 4]), nil) == "Blocked by child 4"
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
    assert stage_label(%Task{stage: :review}, done) == "Review"
    assert approval_label(%Task{stage: :merged}) == "Waiting on you"
  end

  test "a Review run done reads the findings until the review is finished, and then is ready to merge" do
    done = %Run{status: :finished, stage_outcome: :done}
    scratch = Path.join(System.tmp_dir!(), "stage_label_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    task = %Task{stage: :review, scratch_path: scratch, issue: %Issue{identifier: "STL-1"}}
    File.mkdir_p!(Path.join(scratch, "reviews"))

    assert approval_label(task) == "Review"
    refute ready_to_merge?(task, done)

    File.write!(
      Path.join(scratch, "reviews/STL-1.json"),
      ~s({"passes": [{"round": 1, "saved_at": "2026-10-01T10:00:00Z", "head": "abc"}]})
    )

    assert stage_label(task, done) == "Review"
    refute ready_to_merge?(task, done)

    File.write!(
      Path.join(scratch, "reviews/STL-1.json"),
      ~s({"passes": [{"round": 1, "saved_at": "2026-10-01T10:00:00Z", "head": "abc", "finished_at": "2026-10-01T11:00:00Z"}]})
    )

    assert stage_label(task, done) == "Ready to merge"
    assert ready_to_merge?(task, done)
    refute ready_to_merge?(task, %Run{status: :running})
    refute ready_to_merge?(%{task | stage: :engineer}, done)
  end

  test "a Review lead run that stopped, failed or asked reads so, even with a saved pass on disk" do
    scratch = Path.join(System.tmp_dir!(), "stage_label_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    task = %Task{stage: :review, scratch_path: scratch, issue: %Issue{identifier: "STL-2"}}
    File.mkdir_p!(Path.join(scratch, "reviews"))

    File.write!(
      Path.join(scratch, "reviews/STL-2.json"),
      ~s({"passes": [{"round": 1, "saved_at": "2026-10-01T10:00:00Z", "head": "abc"}]})
    )

    lead = %Run{status: :finished, role: %Role{stage: :review_lead}, questions: []}

    assert stage_label(task, lead) == "Review stopped"
    assert stage_label(task, %{lead | error: "The Review lead did not save its review."}) == "Review failed"
    assert stage_label(task, %{lead | questions: [%Question{status: :pending}]}) == "Review needs an answer"
    assert stage_label(task, %{lead | status: :blocked_on_input}) == "Review needs an answer"
  end

  test "only a done Review lead run at Review that is not ready to merge waits on a review" do
    scratch = Path.join(System.tmp_dir!(), "stage_label_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    task = %Task{stage: :review, scratch_path: scratch, issue: %Issue{identifier: "STL-3"}}
    done = %Run{status: :finished, stage_outcome: :done, role: %Role{stage: :review_lead}}

    assert review_waiting?(task, done)

    refute review_waiting?(task, %{done | status: :blocked_on_input})
    refute review_waiting?(task, %{done | stage_outcome: :in_progress})
    refute review_waiting?(task, %{done | stage_outcome: :in_progress, error: "boom"})
    refute review_waiting?(task, %{done | role: %Role{stage: :plan}})
    refute review_waiting?(%{task | stage: :plan}, %{done | role: %Role{stage: :plan}})
    refute review_waiting?(%{task | stage: :engineer}, %{done | role: %Role{stage: :engineer}})
    refute review_waiting?(task, nil)

    File.mkdir_p!(Path.join(scratch, "reviews"))

    File.write!(
      Path.join(scratch, "reviews/STL-3.json"),
      ~s({"passes": [{"round": 1, "saved_at": "2026-10-01T10:00:00Z", "head": "abc", "finished_at": "2026-10-01T11:00:00Z"}]})
    )

    refute review_waiting?(task, done)
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
