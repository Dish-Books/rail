defmodule Rail.PipelineTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
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
  end
end
