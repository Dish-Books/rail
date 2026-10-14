defmodule Rail.Workflows.Actions.SetWorkflowPausedTest do
  use Rail.DataCase, async: true

  alias Rail.Workflows
  alias Rail.Workflows.Schemas.Workflow

  setup %{project: project} do
    [workflow] = sync_workflow_files(project, %{".rail/workflows/dependency-updates.yml" => workflow_yaml()})
    Phoenix.PubSub.subscribe(Rail.PubSub, "workflows")

    %{workflow: workflow}
  end

  test "an admin pauses and resumes a workflow, and each is announced", %{
    project: %{id: project_id},
    workflow: %{id: workflow_id} = workflow
  } do
    admin = user_scope(admin: true)

    assert {:ok, %Workflow{id: ^workflow_id, paused: true}} = Workflows.set_workflow_paused(admin, workflow, true)
    assert_receive {:workflows_changed, ^project_id}

    assert {:ok, %Workflow{paused: false}} = Workflows.set_workflow_paused(admin, workflow, false)
    assert %Workflow{paused: false} = Repo.get!(Workflow, workflow_id)
  end

  test "a workflow read before another tab paused it still resumes", %{workflow: %{id: workflow_id} = stale} do
    {:ok, _paused} = Workflows.set_workflow_paused(user_scope(admin: true), stale, true)

    assert {:ok, %Workflow{paused: false}} = Workflows.set_workflow_paused(user_scope(admin: true), stale, false)
    assert %Workflow{paused: false} = Repo.get!(Workflow, workflow_id)
  end

  test "setting the same state twice leaves it as set", %{workflow: %{id: workflow_id} = workflow} do
    admin = user_scope(admin: true)

    assert {:ok, %Workflow{paused: true}} = Workflows.set_workflow_paused(admin, workflow, true)
    assert {:ok, %Workflow{paused: true}} = Workflows.set_workflow_paused(admin, workflow, true)
    assert %Workflow{paused: true} = Repo.get!(Workflow, workflow_id)
  end

  test "someone who is not an admin is refused", %{workflow: %{id: workflow_id} = workflow} do
    assert {:error, :not_authorized} = Workflows.set_workflow_paused(user_scope(), workflow, true)
    assert %Workflow{paused: false} = Repo.get!(Workflow, workflow_id)
  end
end
