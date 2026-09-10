defmodule Rail.Pipeline.Actions.ApproveStageTest do
  use Rail.DataCase, async: false

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope

  test "returns not_found when task cannot be resolved" do
    assert {:error, :not_found} = Pipeline.approve_stage("tsk_000000000000000000000000")
  end

  test "returns not_authorized when scope lacks permission" do
    task = create_test_task(%{stage_state: :awaiting_approval})
    unauth_scope = %Scope{user: nil, system: false}

    assert {:error, :not_authorized} = Pipeline.approve_stage(unauth_scope, task.id, [])
  end

  test "returns invalid_stage_state when task is not awaiting_approval" do
    task = create_test_task(%{stage_state: :queued})

    assert {:error, {:invalid_stage_state, :queued}} = Pipeline.approve_stage(task)
  end

  test "returns error when task is already at ready_to_merge" do
    task = create_test_task(%{stage: :ready_to_merge, stage_state: :awaiting_approval})

    assert {:error, :cannot_approve_ready_to_merge} = Pipeline.approve_stage(task)
  end

  test "advances product stage to design when design role exists" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    project = create_test_project()
    _design_role = create_test_role(%{project_id: project.id, stage: :design})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :awaiting_approval,
        error: "prior error"
      })

    assert {:ok, %Task{stage: :design, stage_state: :queued, error: nil}} =
             Pipeline.approve_stage(task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :stage_approved}}
  end

  test "advances product stage to architect when skip_design is true" do
    project = create_test_project()
    _design_role = create_test_role(%{project_id: project.id, stage: :design})
    _arch_role = create_test_role(%{project_id: project.id, stage: :architect})

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :architect, stage_state: :queued}} =
             Pipeline.approve_stage(task, skip_design: true)
  end

  test "advances product stage to architect when design role is absent" do
    project = create_test_project()
    _arch_role = create_test_role(%{project_id: project.id, stage: :architect})

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :architect, stage_state: :queued}} =
             Pipeline.approve_stage(task)
  end

  test "advances intermediate stages in standard pipeline order" do
    project = create_test_project()
    _arch = create_test_role(%{project_id: project.id, stage: :architect})
    _eng = create_test_role(%{project_id: project.id, stage: :engineer})
    _rev = create_test_role(%{project_id: project.id, stage: :review})
    _qa = create_test_role(%{project_id: project.id, stage: :qa})
    _lead = create_test_role(%{project_id: project.id, stage: :qa_lead})

    t_design = create_test_task(%{project_id: project.id, stage: :design, stage_state: :awaiting_approval})
    assert {:ok, %Task{stage: :architect}} = Pipeline.approve_stage(t_design)

    t_arch = create_test_task(%{project_id: project.id, stage: :architect, stage_state: :awaiting_approval})
    assert {:ok, %Task{stage: :engineer}} = Pipeline.approve_stage(t_arch)

    t_eng = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :awaiting_approval})
    assert {:ok, %Task{stage: :review}} = Pipeline.approve_stage(t_eng)

    t_rev = create_test_task(%{project_id: project.id, stage: :review, stage_state: :awaiting_approval})
    assert {:ok, %Task{stage: :qa}} = Pipeline.approve_stage(t_rev)

    t_qa = create_test_task(%{project_id: project.id, stage: :qa, stage_state: :awaiting_approval})
    assert {:ok, %Task{stage: :qa_lead}} = Pipeline.approve_stage(t_qa)
  end

  test "advances qa_lead to demo if demo role exists" do
    project = create_test_project()
    _demo = create_test_role(%{project_id: project.id, stage: :demo})

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :qa_lead,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :demo, stage_state: :queued}} =
             Pipeline.approve_stage(task)
  end

  test "advances qa_lead to ready_to_merge awaiting_approval if demo role absent" do
    project = create_test_project()

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :qa_lead,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}} =
             Pipeline.approve_stage(task)
  end

  test "advances demo stage to ready_to_merge awaiting_approval" do
    project = create_test_project()

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :demo,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}} =
             Pipeline.approve_stage(task)
  end

  test "sets stage_state to failed when next stage has no configured role" do
    project = create_test_project()

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :architect,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :engineer, stage_state: :failed, error: err}} =
             Pipeline.approve_stage(task)

    assert err =~ "No role is configured for the engineer stage"
  end

  test "supports scope-based invocation with task struct or id" do
    project = create_test_project()
    _arch = create_test_role(%{project_id: project.id, stage: :architect})
    scope = Scope.for_system()

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :design,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :architect}} = Pipeline.approve_stage(scope, task, [])
  end

  test "authorizes scope with user and supports 2-argument invocation" do
    project = create_test_project()
    _arch = create_test_role(%{project_id: project.id, stage: :architect})
    user_scope = %Scope{user: %{id: "usr_test"}, system: false}

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :design,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :architect}} = Pipeline.approve_stage(user_scope, task.id)
    assert {:error, :not_found} = Pipeline.approve_stage(user_scope, :invalid_task)
  end
end
