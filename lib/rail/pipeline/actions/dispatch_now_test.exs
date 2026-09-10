defmodule Rail.Pipeline.Actions.DispatchNowTest do
  use Rail.DataCase, async: false

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope

  test "returns not_authorized when scope lacks permission" do
    unauth = %Scope{user: nil, system: false}
    assert {:error, :not_authorized} = Pipeline.dispatch_now(unauth, "tsk_123")
  end

  test "returns dispatch_disabled when explicitly disabled" do
    task = create_test_task(%{stage: :product, stage_state: :queued})

    assert {:error, :dispatch_disabled} =
             Pipeline.dispatch_now(task, dispatch_disabled: true)
  end

  test "returns dispatch_disabled when RAIL_NO_DISPATCH=1 is set in env" do
    Application.put_env(:rail, :no_dispatch, false)
    System.put_env("RAIL_NO_DISPATCH", "1")

    task = create_test_task(%{stage: :product, stage_state: :queued})
    assert {:error, :dispatch_disabled} = Pipeline.dispatch_now(task)

    System.delete_env("RAIL_NO_DISPATCH")
    Application.put_env(:rail, :no_dispatch, true)
  end

  test "returns not_found when task identifier is invalid or does not exist" do
    opts = [dispatch_disabled: false]
    assert {:error, :not_found} = Pipeline.dispatch_now("tsk_000000000000000000000000", opts)
    assert {:error, :not_found} = Pipeline.dispatch_now(1234, opts)
    assert {:error, :not_found} = Pipeline.dispatch_now(:invalid_id, opts)
  end

  test "returns not_queued when task is not in queued stage_state" do
    opts = [dispatch_disabled: false]
    running_task = create_test_task(%{stage: :product, stage_state: :running})
    failed_task = create_test_task(%{stage: :product, stage_state: :failed})

    assert {:error, {:not_queued, :running}} = Pipeline.dispatch_now(running_task, opts)
    assert {:error, {:not_queued, :failed}} = Pipeline.dispatch_now(failed_task, opts)
  end

  test "returns waiting_to_retry when task retry_after is in the future" do
    future = DateTime.shift(DateTime.utc_now(), minute: 5)

    task =
      create_test_task(%{
        stage: :product,
        stage_state: :queued,
        retry_after: future
      })

    assert {:error, :waiting_to_retry} =
             Pipeline.dispatch_now(task, dispatch_disabled: false)
  end

  test "returns project_not_found when task references nonexistent project" do
    %Task{} = task = create_test_task(%{stage: :product, stage_state: :queued})
    task_with_bad_project = %{task | project_id: "prj_000000000000000000000000"}

    assert {:error, :project_not_found} =
             Pipeline.dispatch_now(task_with_bad_project, dispatch_disabled: false)
  end

  test "returns no_role_for_stage when no role configured for stage" do
    project = create_test_project()
    task = create_test_task(%{project_id: project.id, stage: :design, stage_state: :queued})

    assert {:error, {:no_role_for_stage, :design}} =
             Pipeline.dispatch_now(task, dispatch_disabled: false)
  end

  test "returns no_available_slots when role concurrency is exhausted" do
    project = create_test_project()
    _role = create_test_role(%{project_id: project.id, stage: :product, max_concurrent: 1})
    _running = create_test_task(%{project_id: project.id, stage: :product, stage_state: :running})
    task = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})

    assert {:error, :no_available_slots} =
             Pipeline.dispatch_now(task, dispatch_disabled: false)
  end

  test "dispatches immediately when slots are available using custom dispatch hook" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :product, max_concurrent: 2})
    %Task{id: task_id} = task = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})

    caller = self()

    hook = fn t, r ->
      send(caller, {:dispatched_hook, t.id, r.id})
      {:ok, %{t | stage_state: :running}}
    end

    opts = [dispatch_disabled: false, dispatch_hook: hook]

    assert {:ok, %Task{id: ^task_id, stage_state: :running}} =
             Pipeline.dispatch_now(task, opts)

    assert_receive {:dispatched_hook, ^task_id, r_id}
    assert r_id == role.id
  end

  test "dispatches task when retry_after has elapsed in the past" do
    project = create_test_project()
    _role = create_test_role(%{project_id: project.id, stage: :product, max_concurrent: 1})
    past = DateTime.shift(DateTime.utc_now(), minute: -5)

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        retry_after: past
      })

    opts = [dispatch_disabled: false, dispatch_hook: &mock_dispatch_hook/2]

    assert {:ok, %Task{id: ^task_id, stage_state: :running}} =
             Pipeline.dispatch_now(task, opts)
  end

  test "resolves engineer role for rebasing tasks" do
    project = create_test_project()
    _role_eng = create_test_role(%{project_id: project.id, stage: :engineer, max_concurrent: 1})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :queued,
        is_rebasing: true
      })

    opts = [dispatch_disabled: false, dispatch_hook: &mock_dispatch_hook/2]

    assert {:ok, %Task{id: ^task_id, stage_state: :running}} =
             Pipeline.dispatch_now(task, opts)
  end

  test "supports all arity and scope variations" do
    project = create_test_project()
    _role = create_test_role(%{project_id: project.id, stage: :product, max_concurrent: 5})

    t1 = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})
    t2 = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})
    t3 = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})

    opts = [dispatch_disabled: false, dispatch_hook: &mock_dispatch_hook/2]

    # scope with opts
    sys = Scope.for_system()
    assert {:ok, %Task{stage_state: :running}} = Pipeline.dispatch_now(sys, t1, opts)

    # user scope without opts
    user_scope = %Scope{user: %{id: "usr_123"}, system: false}
    assert {:error, :dispatch_disabled} = Pipeline.dispatch_now(user_scope, t2)

    # task_or_id with opts
    assert {:ok, %Task{stage_state: :running}} = Pipeline.dispatch_now(t3.id, opts)

    # 1-arity default
    t4 = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})
    assert {:error, :dispatch_disabled} = Pipeline.dispatch_now(t4)
  end

  test "dispatches via default supervised runner when git repo exists" do
    repo_dir = create_temp_git_repo()
    project = create_test_project(%{clone_path: repo_dir, default_branch: "main"})
    _role = create_test_role(%{project_id: project.id, stage: :product})
    %Task{id: task_id} = task = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})

    assert {:ok, %Task{id: ^task_id}} =
             Pipeline.dispatch_now(task, dispatch_disabled: false)
  end
end
