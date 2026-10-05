defmodule RailWeb.Utils.RoleStatusLabelTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.RoleStatusLabel

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role

  test "a role that has never run has not started" do
    assert role_status_label(%Role{stage: :product}, nil, %Task{stage: :product}) == "not started"
  end

  test "a run says what it is doing" do
    role = %Role{stage: :product}
    task = %Task{stage: :product}

    assert role_status_label(role, %Run{status: :running}, task) == "in progress"
    assert role_status_label(role, %Run{status: :blocked_on_input}, task) == "needs an answer"
    assert role_status_label(role, %Run{status: :finished, error: "boom"}, task) == "failed"
    assert role_status_label(role, %Run{status: :finished}, task) == "stopped"
    assert role_status_label(role, %Run{status: :waiting_for_resources}, task) == "waiting for resources"
    assert role_status_label(role, %Run{status: :waiting_for_usage}, task) == "waiting for usage"
  end

  test "the role for the stage the task sits at says what to go and read" do
    done = %Run{status: :finished, stage_outcome: :done}

    assert role_status_label(%Role{stage: :product}, done, %Task{stage: :product}) == "review the ticket"
    assert role_status_label(%Role{stage: :design}, done, %Task{stage: :design}) == "review the designs"
    assert role_status_label(%Role{stage: :architect}, done, %Task{stage: :architect}) == "review the plan"
    assert role_status_label(%Role{stage: :engineer}, done, %Task{stage: :engineer}) == "needs review"
  end

  test "QA sent back for evidence says it is fixing its report, or that its report is not valid" do
    qa = %Role{stage: :qa}
    task = %Task{stage: :qa}

    assert role_status_label(qa, %Run{status: :running, evidence_reminders: 1}, task) == "fixing its report"

    assert role_status_label(qa, %Run{status: :finished, evidence_reminders: 2, error: "QA's report..."}, task) ==
             "report not valid"

    assert role_status_label(qa, %Run{status: :running, evidence_reminders: 0}, task) == "in progress"

    assert role_status_label(qa, %Run{status: :running, evidence_reminders: 1}, %Task{stage: :demo}) ==
             "fixing its report"

    assert role_status_label(%Role{stage: :engineer}, %Run{status: :running, evidence_reminders: 1}, task) ==
             "in progress"
  end

  test "a role the task has moved past is only done" do
    done = %Run{status: :finished, stage_outcome: :done}

    assert role_status_label(%Role{stage: :product}, done, %Task{stage: :architect}) == "done"
  end
end
