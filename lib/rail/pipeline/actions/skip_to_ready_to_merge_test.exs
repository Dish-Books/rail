defmodule Rail.Pipeline.Actions.SkipToReadyToMergeTest do
  use Rail.DataCase, async: false

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope

  test "returns not_found when task cannot be resolved" do
    assert {:error, :not_found} = Pipeline.skip_to_ready_to_merge("tsk_000000000000000000000000")
  end

  test "returns not_authorized when scope lacks permission" do
    task = create_test_task(%{stage: :review, stage_state: :awaiting_approval})
    unauth_scope = %Scope{user: nil, system: false}

    assert {:error, :not_authorized} = Pipeline.skip_to_ready_to_merge(unauth_scope, task.id)
  end

  test "returns invalid_stage_state when task is not awaiting_approval" do
    t_queued = create_test_task(%{stage: :review, stage_state: :queued})
    assert {:error, {:invalid_stage_state, :queued}} = Pipeline.skip_to_ready_to_merge(t_queued)

    t_running = create_test_task(%{stage: :review, stage_state: :running})
    assert {:error, {:invalid_stage_state, :running}} = Pipeline.skip_to_ready_to_merge(t_running)
  end

  test "returns invalid_stage when task is not at a gate stage" do
    t_eng = create_test_task(%{stage: :engineer, stage_state: :awaiting_approval})
    assert {:error, {:invalid_stage, :engineer}} = Pipeline.skip_to_ready_to_merge(t_eng)

    t_prod = create_test_task(%{stage: :product, stage_state: :awaiting_approval})
    assert {:error, {:invalid_stage, :product}} = Pipeline.skip_to_ready_to_merge(t_prod)

    t_arch = create_test_task(%{stage: :architect, stage_state: :awaiting_approval})
    assert {:error, {:invalid_stage, :architect}} = Pipeline.skip_to_ready_to_merge(t_arch)
  end

  test "skips to ready_to_merge awaiting_approval from review gate" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    %Task{id: task_id} =
      task =
      create_test_task(%{
        stage: :review,
        stage_state: :awaiting_approval,
        error: "Parked on findings"
      })

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :ready_to_merge,
              stage_state: :awaiting_approval,
              error: nil
            }} = Pipeline.skip_to_ready_to_merge(task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :skipped_to_ready_to_merge}}
  end

  test "skips to ready_to_merge awaiting_approval from qa and qa_lead gates" do
    t_qa = create_test_task(%{stage: :qa, stage_state: :awaiting_approval})

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}} =
             Pipeline.skip_to_ready_to_merge(t_qa)

    t_lead = create_test_task(%{stage: :qa_lead, stage_state: :awaiting_approval})

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}} =
             Pipeline.skip_to_ready_to_merge(t_lead)
  end

  test "supports scope-based invocation with task id" do
    task = create_test_task(%{stage: :review, stage_state: :awaiting_approval})
    scope = Scope.for_system()

    assert {:ok, %Task{stage: :ready_to_merge}} =
             Pipeline.skip_to_ready_to_merge(scope, task.id)
  end

  test "authorizes scope with user and handles invalid task argument" do
    task = create_test_task(%{stage: :review, stage_state: :awaiting_approval})
    user_scope = %Scope{user: %{id: "usr_test"}, system: false}

    assert {:ok, %Task{stage: :ready_to_merge}} = Pipeline.skip_to_ready_to_merge(user_scope, task.id)
    assert {:error, :not_found} = Pipeline.skip_to_ready_to_merge(user_scope, :invalid_task)
  end
end
