defmodule Rail.PipelineTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope

  test "delegates get_task and get_task!" do
    scope = Scope.for_system()
    %Task{id: task_id} = create_test_task()

    assert {:ok, %Task{id: ^task_id}} = Pipeline.get_task(scope, task_id)
    assert %Task{id: ^task_id} = Pipeline.get_task!(scope, task_id)
  end

  test "delegates list_tasks" do
    project = create_test_project()
    %Task{id: task_id} = create_test_task(%{project_id: project.id})
    scope = Scope.for_system()

    assert [%Task{id: ^task_id}] = Pipeline.list_tasks(scope, project.id)
  end

  test "delegates broadcast_pipeline_changed" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    assert :ok = Pipeline.broadcast_pipeline_changed(%{test: true})
    assert_receive {:pipeline_changed, %{test: true}}
  end

  test "delegates list_eligible_tasks" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :product})
    %Task{id: task_id} = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})

    assert [%Task{id: ^task_id}] = Pipeline.list_eligible_tasks(project, role)
  end

  test "delegates dispatcher controls" do
    assert Pipeline.dispatch_disabled?() == true
    assert match?({:disabled, []}, Pipeline.pump_dispatcher())
    assert match?({:error, :dispatch_disabled}, Pipeline.dispatch_now("tsk_dummy"))
    assert Pipeline.retry_timers() == %{}
    assert :ok = Pipeline.rearm_pending_retries()
    assert :ok = Pipeline.cancel_retry_timer("tsk_dummy")
    assert {:error, :not_waiting_to_retry} = Pipeline.arm_retry_timer("tsk_dummy")
  end

  test "delegates stage lifecycle and gate actions" do
    project = create_test_project()
    _arch = create_test_role(%{project_id: project.id, stage: :architect})
    _eng = create_test_role(%{project_id: project.id, stage: :engineer})

    task_approve = create_test_task(%{project_id: project.id, stage: :design, stage_state: :awaiting_approval})
    assert {:ok, %Task{stage: :architect}} = Pipeline.approve_stage(task_approve)

    task_request = create_test_task(%{project_id: project.id, stage: :architect, stage_state: :awaiting_approval})
    assert {:ok, %Task{stage: :architect, stage_state: :queued}} = Pipeline.request_changes(task_request, "Fix schema")

    task_send_back = create_test_task(%{project_id: project.id, stage: :review, stage_state: :awaiting_approval})

    assert {:ok, %Task{stage: :engineer, stage_state: :queued}} =
             Pipeline.send_back_to_engineer(task_send_back, "Rework please")

    task_skip = create_test_task(%{stage: :review, stage_state: :awaiting_approval})

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}} =
             Pipeline.skip_to_ready_to_merge(task_skip)

    task_retry = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :failed})
    assert {:ok, %Task{stage_state: :queued}} = Pipeline.retry_stage(task_retry)

    task_retry_opts = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :failed})

    assert {:ok, %Task{stage_state: :queued}} =
             Pipeline.retry_stage(Scope.for_system(), task_retry_opts.id, [])
  end

  test "delegates question lifecycle and listing actions" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :engineer})
    _review_role = create_test_role(%{project_id: project.id, stage: :review})
    task = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :running})
    role_run = create_test_role_run(%{task_id: task.id, role_id: role.id, status: :running})
    scope = Scope.for_system()

    assert {:ok, %Question{id: q_id, prompt: "DB?"}} =
             Pipeline.register_question(task, role_run, %{prompt: "DB?"}, [])

    assert {:ok, %Question{id: ^q_id}} = Pipeline.get_question(scope, q_id)
    assert %Question{id: ^q_id} = Pipeline.get_question!(scope, q_id)

    assert [%Question{id: ^q_id}] =
             Pipeline.list_questions(scope, project.id, status: :pending)

    assert [%Question{id: ^q_id}] =
             Pipeline.list_pending_questions(scope, project.id, [])

    assert {:ok, %Task{stage: :review, stage_state: :queued}} = Pipeline.release_blocked_stage(scope, task.id)

    assert {:ok, %Question{status: :answered}} =
             Pipeline.answer_question(scope, q_id, "Postgres")

    q_dismiss = create_test_question(%{status: :pending})

    assert {:ok, %Question{status: :dismissed}} =
             Pipeline.dismiss_question(scope, q_dismiss.id)
  end
end
