defmodule RailWeb.Utils.RoleStatusLabelTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.RoleStatusLabel

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role

  test "a role that has never run has not started" do
    assert role_status_label(%Role{stage: :plan}, nil, %Task{stage: :plan}) == "not started"
  end

  test "a run says what it is doing" do
    role = %Role{stage: :plan}
    task = %Task{stage: :plan}

    assert role_status_label(role, %Run{status: :running}, task) == "in progress"
    assert role_status_label(role, %Run{status: :blocked_on_input}, task) == "needs an answer"
    assert role_status_label(role, %Run{status: :finished, error: "boom"}, task) == "failed"
    assert role_status_label(role, %Run{status: :finished}, task) == "stopped"
    assert role_status_label(role, %Run{status: :waiting_for_resources}, task) == "waiting for resources"
    assert role_status_label(role, %Run{status: :waiting_for_usage}, task) == "waiting for usage"
  end

  test "the role for the stage the task sits at says what to go and read" do
    done = %Run{status: :finished, stage_outcome: :done}
    scratch = Path.join(System.tmp_dir!(), "role_status_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    plan_task = %Task{stage: :plan, scratch_path: scratch}

    assert role_status_label(%Role{stage: :plan}, done, plan_task) == "review the plan"
    assert role_status_label(%Role{stage: :review_lead}, done, %Task{stage: :review}) == "review"
    assert role_status_label(%Role{stage: :engineer}, done, %Task{stage: :engineer}) == "needs review"

    options = for key <- ["a", "b", "c"], do: %{"key" => key, "title" => String.upcase(key)}
    File.mkdir_p!(Path.join(scratch, "design"))
    File.write!(Path.join(scratch, "design/manifest.json"), Jason.encode!(%{"options" => options}))

    assert role_status_label(%Role{stage: :plan}, done, plan_task) == "pick a design"
  end

  test "the Review lead reads ready to merge once the review is finished" do
    done = %Run{status: :finished, stage_outcome: :done}
    scratch = Path.join(System.tmp_dir!(), "role_status_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    File.mkdir_p!(Path.join(scratch, "reviews"))

    File.write!(
      Path.join(scratch, "reviews/RSL-1.json"),
      ~s({"passes": [{"round": 1, "saved_at": "2026-10-01T10:00:00Z", "finished_at": "2026-10-01T11:00:00Z"}]})
    )

    task = %Task{stage: :review, scratch_path: scratch, issue: %Issue{identifier: "RSL-1"}}

    assert role_status_label(%Role{stage: :review_lead}, done, task) == "ready to merge"
    assert role_status_label(%Role{stage: :review_lead}, %Run{status: :running}, task) == "in progress"
    assert role_status_label(%Role{stage: :engineer}, done, task) == "done"
  end

  test "a role the task has moved past is only done" do
    done = %Run{status: :finished, stage_outcome: :done}

    assert role_status_label(%Role{stage: :plan}, done, %Task{stage: :engineer}) == "done"
  end
end
