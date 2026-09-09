defmodule Rail.Pipeline.Actions.RetryStageTest do
  use Rail.DataCase, async: false

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Scope

  test "returns not_found when task cannot be resolved" do
    assert {:error, :not_found} = Pipeline.retry_stage("tsk_000000000000000000000000")
  end

  test "returns not_authorized when scope lacks permission" do
    task = create_test_task(%{stage: :engineer, stage_state: :failed})
    unauth_scope = %Scope{user: nil, system: false}

    assert {:error, :not_authorized} = Pipeline.retry_stage(unauth_scope, task.id)
  end

  test "returns no_role_for_stage when stage lacks a configured role" do
    project = create_test_project()
    task = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :failed})

    assert {:error, {:no_role_for_stage, :engineer}} = Pipeline.retry_stage(task)
  end

  test "clears retry_after and error, sets stage_state to queued, and resets auto_retries" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    project = create_test_project()
    role_eng = create_test_role(%{project_id: project.id, stage: :engineer, name: "Engineer"})

    retry_time = DateTime.shift(DateTime.utc_now(), minute: 1)

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :engineer,
        stage_state: :failed,
        retry_after: retry_time,
        error: "Transient socket hang up"
      })

    create_test_role_run(%{
      task_id: task_id,
      role_id: role_eng.id,
      status: :finished,
      auto_retries: 2
    })

    assert {:ok,
            %Task{
              id: ^task_id,
              stage_state: :queued,
              retry_after: nil,
              error: nil
            }} = Pipeline.retry_stage(task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :stage_retried}}

    eng_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
    assert eng_run.auto_retries == 0
  end

  test "resolves engineer role when task is rebasing" do
    project = create_test_project()
    role_eng = create_test_role(%{project_id: project.id, stage: :engineer, name: "Engineer"})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :failed,
        is_rebasing: true,
        error: "Merge conflict"
      })

    create_test_role_run(%{
      task_id: task_id,
      role_id: role_eng.id,
      status: :finished,
      auto_retries: 1
    })

    assert {:ok, %Task{id: ^task_id, stage_state: :queued, error: nil}} =
             Pipeline.retry_stage(task)

    eng_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
    assert eng_run.auto_retries == 0
  end

  test "handles retry when role_run row does not exist yet" do
    project = create_test_project()
    _role = create_test_role(%{project_id: project.id, stage: :product})

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :failed,
        error: "Initial startup error"
      })

    assert {:ok, %Task{stage_state: :queued, error: nil}} =
             Pipeline.retry_stage(task)
  end

  test "supports scope-based invocation with task id" do
    project = create_test_project()
    _role = create_test_role(%{project_id: project.id, stage: :product})
    task = create_test_task(%{project_id: project.id, stage: :product, stage_state: :failed})

    scope = Scope.for_system()
    assert {:ok, %Task{stage_state: :queued}} = Pipeline.retry_stage(scope, task.id)
  end

  test "authorizes scope with user and handles invalid task argument" do
    project = create_test_project()
    _role = create_test_role(%{project_id: project.id, stage: :product})
    task = create_test_task(%{project_id: project.id, stage: :product, stage_state: :failed})
    user_scope = %Scope{user: %{id: "usr_test"}, system: false}

    assert {:ok, %Task{stage_state: :queued}} = Pipeline.retry_stage(user_scope, task.id)
    assert {:error, :not_found} = Pipeline.retry_stage(user_scope, :invalid_task)
  end
end
