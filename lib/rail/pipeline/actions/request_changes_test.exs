defmodule Rail.Pipeline.Actions.RequestChangesTest do
  use Rail.DataCase, async: false

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Scope

  test "returns not_found when task cannot be resolved" do
    assert {:error, :not_found} = Pipeline.request_changes("tsk_000000000000000000000000", "Fix this")
  end

  test "returns not_authorized when scope lacks permission" do
    task = create_test_task(%{stage: :engineer, stage_state: :awaiting_approval})
    unauth_scope = %Scope{user: nil, system: false}

    assert {:error, :not_authorized} = Pipeline.request_changes(unauth_scope, task.id, "Fix this")
  end

  test "returns empty_comment when comment is empty or whitespace" do
    task = create_test_task(%{stage: :engineer, stage_state: :awaiting_approval})

    assert {:error, :empty_comment} = Pipeline.request_changes(task, "")
    assert {:error, :empty_comment} = Pipeline.request_changes(task, "   ")
    assert {:error, :empty_comment} = Pipeline.request_changes(task, nil)
  end

  test "returns no_role_for_stage when target stage role is not configured" do
    project = create_test_project()
    task = create_test_task(%{project_id: project.id, stage: :architect, stage_state: :awaiting_approval})

    assert {:error, {:no_role_for_stage, :architect}} =
             Pipeline.request_changes(task, "Please rethink architecture")
  end

  test "queues target stage and appends comment to role_run pending_answer" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    project = create_test_project()
    role_arch = create_test_role(%{project_id: project.id, stage: :architect, name: "Architect"})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :architect,
        stage_state: :awaiting_approval,
        error: "Some error"
      })

    create_test_role_run(%{
      task_id: task_id,
      role_id: role_arch.id,
      status: :finished,
      auto_retries: 2,
      pending_answer: "Initial notes"
    })

    assert {:ok, %Task{id: ^task_id, stage: :architect, stage_state: :queued, error: nil}} =
             Pipeline.request_changes(task, "Clarify database model")

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :changes_requested}}

    arch_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_arch.id)
    assert arch_run.pending_answer == "Initial notes\n\nClarify database model"
    assert arch_run.auto_retries == 0
  end

  test "creates role_run if one did not exist yet" do
    project = create_test_project()
    role_rev = create_test_role(%{project_id: project.id, stage: :review, name: "Reviewer"})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :review,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :review, stage_state: :queued}} =
             Pipeline.request_changes(task, "Add test coverage")

    rev_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_rev.id)
    assert rev_run.pending_answer == "Add test coverage"
    assert rev_run.auto_retries == 0
  end

  test "delegates to send_back_to_engineer when target stage is ready_to_merge" do
    project = create_test_project()
    role_eng = create_test_role(%{project_id: project.id, stage: :engineer, name: "Engineer"})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{id: ^task_id, stage: :engineer, stage_state: :queued}} =
             Pipeline.request_changes(task, "Need bugfix before merge", stage: :ready_to_merge)

    eng_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
    assert eng_run.pending_answer =~ "What the human asked for:\n\nNeed bugfix before merge"
  end

  test "routes to engineer while preserving task.stage when task is rebasing" do
    project = create_test_project()
    role_eng = create_test_role(%{project_id: project.id, stage: :engineer, name: "Engineer"})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :qa,
        stage_state: :running,
        is_rebasing: true
      })

    assert {:ok, %Task{stage: :qa, stage_state: :queued}} =
             Pipeline.request_changes(task, "Resolve merge conflict cleanly")

    eng_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
    assert eng_run.pending_answer =~ "Resolve merge conflict cleanly"
  end

  test "authorizes scope with user and handles invalid task argument" do
    project = create_test_project()
    _role_eng = create_test_role(%{project_id: project.id, stage: :engineer, name: "Engineer"})
    task = create_test_task(%{project_id: project.id, stage: :ready_to_merge, stage_state: :awaiting_approval})
    user_scope = %Scope{user: %{id: "usr_test"}, system: false}

    assert {:ok, %Task{stage: :engineer}} = Pipeline.request_changes(user_scope, task.id, "Need rework")
    assert {:ok, %Task{stage: :engineer}} = Pipeline.request_changes(user_scope, task.id, "Need rework", stage: :engineer)
    assert {:error, :not_found} = Pipeline.request_changes(user_scope, :invalid_task, "Need rework")
  end
end
