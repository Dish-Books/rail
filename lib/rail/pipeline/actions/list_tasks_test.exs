defmodule Rail.Pipeline.Actions.ListTasksTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope

  test "lists tasks for project under system and user scope" do
    project = create_test_project()
    %Task{id: id1} = create_test_task(%{project_id: project.id, title: "T1"})
    %Task{id: id2} = create_test_task(%{project_id: project.id, title: "T2"})

    system_scope = Scope.for_system()
    user_scope = Scope.for_user(%{admin: false})

    assert [%Task{id: ^id1}, %Task{id: ^id2}] = Pipeline.list_tasks(system_scope, project.id)
    assert [%Task{id: ^id1}, %Task{id: ^id2}] = Pipeline.list_tasks(user_scope, project.id)
  end

  test "returns empty list for unauthorized scope" do
    project = create_test_project()
    _t1 = create_test_task(%{project_id: project.id})

    assert [] = Pipeline.list_tasks(nil, project.id)
    assert [] = Pipeline.list_tasks(%Scope{user: nil, system: false}, project.id)
  end

  test "filters tasks by stage and stage_state" do
    project = create_test_project()

    %Task{id: prod_id} =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued
      })

    %Task{id: eng_q_id} =
      create_test_task(%{
        project_id: project.id,
        stage: :engineer,
        stage_state: :queued
      })

    _t_eng_running =
      create_test_task(%{
        project_id: project.id,
        stage: :engineer,
        stage_state: :running
      })

    scope = Scope.for_system()

    # Filter by stage
    assert [%Task{id: ^prod_id}] = Pipeline.list_tasks(scope, project.id, stage: :product)

    # Filter by stage and stage_state
    assert [%Task{id: ^eng_q_id}] =
             Pipeline.list_tasks(scope, project.id, stage: :engineer, stage_state: :queued)
  end

  test "supports custom order_by" do
    project = create_test_project()
    %Task{id: id1} = create_test_task(%{project_id: project.id, title: "Alpha"})
    %Task{id: id2} = create_test_task(%{project_id: project.id, title: "Beta"})

    scope = Scope.for_system()

    assert [%Task{id: ^id2}, %Task{id: ^id1}] =
             Pipeline.list_tasks(scope, project.id, order_by: [desc: :inserted_at])
  end
end
