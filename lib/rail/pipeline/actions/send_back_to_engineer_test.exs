defmodule Rail.Pipeline.Actions.SendBackToEngineerTest do
  use Rail.DataCase, async: false

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Scope

  test "returns not_found when task cannot be resolved" do
    assert {:error, :not_found} = Pipeline.send_back_to_engineer("tsk_000000000000000000000000")
  end

  test "returns not_authorized when scope lacks permission" do
    task = create_test_task(%{stage: :review, stage_state: :awaiting_approval})
    unauth_scope = %Scope{user: nil, system: false}

    assert {:error, :not_authorized} = Pipeline.send_back_to_engineer(unauth_scope, task.id, [])
  end

  test "returns task_running when task is currently running" do
    task = create_test_task(%{stage: :review, stage_state: :running})

    assert {:error, :task_running} = Pipeline.send_back_to_engineer(task)
  end

  test "returns stage_before_engineer for product, design, and architect stages" do
    t_prod = create_test_task(%{stage: :product, stage_state: :awaiting_approval})
    assert {:error, :stage_before_engineer} = Pipeline.send_back_to_engineer(t_prod)

    t_des = create_test_task(%{stage: :design, stage_state: :awaiting_approval})
    assert {:error, :stage_before_engineer} = Pipeline.send_back_to_engineer(t_des)

    t_arch = create_test_task(%{stage: :architect, stage_state: :awaiting_approval})
    assert {:error, :stage_before_engineer} = Pipeline.send_back_to_engineer(t_arch)
  end

  test "returns task_merged when task is in merged stage" do
    task = create_test_task(%{stage: :merged, stage_state: :awaiting_approval})

    assert {:error, :task_merged} = Pipeline.send_back_to_engineer(task)
  end

  test "returns no_engineer_role when project lacks an engineer role" do
    project = create_test_project()

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :review,
        stage_state: :awaiting_approval
      })

    assert {:error, :no_engineer_role} = Pipeline.send_back_to_engineer(task)
  end

  test "grants fresh budget, collects gate reports, and queues engineer with pending answer" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    project = create_test_project()
    role_eng = create_test_role(%{project_id: project.id, stage: :engineer, name: "Staff Engineer"})
    role_rev = create_test_role(%{project_id: project.id, stage: :review, name: "Lead Reviewer"})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :review,
        stage_state: :awaiting_approval,
        rework_cycles: 4,
        rework_budget_base: 0,
        rework_cycles_by_gate: %{role_rev.id => 3},
        outstanding_reports: [role_rev.id],
        error: "Rework limit reached"
      })

    create_test_role_run(%{
      task_id: task_id,
      role_id: role_rev.id,
      status: :finished,
      output: "Reviewer finding: memory leak in loop."
    })

    expected_empty = %{}

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :engineer,
              stage_state: :queued,
              rework_cycles: 4,
              rework_budget_base: 4,
              rework_cycles_by_gate: ^expected_empty,
              outstanding_reports: [],
              error: nil
            }} = Pipeline.send_back_to_engineer(task, comment: "Please address memory leak.")

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :sent_back_to_engineer}}

    eng_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
    assert eng_run.pending_answer =~ "Sent back to you by the human"
    assert eng_run.pending_answer =~ "What the human asked for:\n\nPlease address memory leak."
    assert eng_run.pending_answer =~ "### Lead Reviewer\n\nReviewer finding: memory leak in loop."
  end

  test "supports string comment directly or empty note" do
    project = create_test_project()
    role_eng = create_test_role(%{project_id: project.id, stage: :engineer, name: "Staff Engineer"})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :qa,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :engineer, stage_state: :queued}} =
             Pipeline.send_back_to_engineer(task, "Direct string comment")

    eng_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
    assert eng_run.pending_answer =~ "What the human asked for:\n\nDirect string comment"
  end

  test "appends to existing engineer pending_answer, authorizes user scope, and handles non-list note" do
    project = create_test_project()
    role_eng = create_test_role(%{project_id: project.id, stage: :engineer, name: "Staff Engineer"})
    user_scope = %Scope{user: %{id: "usr_test"}, system: false}

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :review,
        stage_state: :awaiting_approval
      })

    create_test_role_run(%{
      task_id: task_id,
      role_id: role_eng.id,
      status: :finished,
      pending_answer: "Initial engineer instruction"
    })

    assert {:ok, %Task{stage: :engineer, stage_state: :queued}} =
             Pipeline.send_back_to_engineer(user_scope, task.id)

    assert {:ok, %Task{stage: :engineer, stage_state: :queued}} =
             Pipeline.send_back_to_engineer(user_scope, task.id, comment: nil)

    assert {:ok, %Task{stage: :engineer, stage_state: :queued}} =
             Pipeline.send_back_to_engineer(task, :non_list_opts)

    eng_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
    assert eng_run.pending_answer =~ "Initial engineer instruction\n\nSent back to you by the human"

    assert {:error, :not_found} = Pipeline.send_back_to_engineer(user_scope, :invalid_task)
  end
end
