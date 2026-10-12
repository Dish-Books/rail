defmodule Rail.Workflows.Actions.ListWorkflowsTest do
  use Rail.DataCase, async: true

  alias Rail.Projects.Schemas.Project
  alias Rail.Workflows
  alias Rail.Workflows.Schemas.Workflow

  test "lists workflows by project name, then path, with their project", %{project: project, github_project: github} do
    sync_workflow_files(project, %{
      ".rail/workflows/sweep.yml" => workflow_yaml(),
      ".rail/workflows/audit.yml" => workflow_yaml()
    })

    sync_workflow_files(github, %{".rail/workflows/deps.yml" => workflow_yaml()})

    assert {:ok,
            [
              %Workflow{path: ".rail/workflows/deps.yml", project: %Project{name: "Test GitHub Project"}},
              %Workflow{path: ".rail/workflows/audit.yml", project: %Project{name: "Test Project"}},
              %Workflow{path: ".rail/workflows/sweep.yml"}
            ]} = Workflows.list_workflows(user_scope(admin: true), [])
  end

  test "the due filter keeps paused workflows and leaves out those due later", %{project: project} do
    [%Workflow{id: daily_id} = daily, %Workflow{next_run_at: ~U[2026-10-12 09:00:00Z]}] =
      sync_workflow_files(project, %{
        ".rail/workflows/daily.yml" => workflow_yaml(%{"schedule" => "0 6 * * *"}),
        ".rail/workflows/weekly.yml" => workflow_yaml()
      })

    {:ok, _paused} = Workflows.set_workflow_paused(system_scope(), daily, true)

    # Synced at 08:00 on Monday: daily next runs Tuesday 06:00, weekly today at 09:00.
    assert {:ok, []} = Workflows.list_workflows(system_scope(), due: ~U[2026-10-12 08:59:00Z])

    assert {:ok, [%Workflow{path: ".rail/workflows/weekly.yml"}]} =
             Workflows.list_workflows(system_scope(), due: ~U[2026-10-12 09:00:00Z])

    assert {:ok, [%Workflow{id: ^daily_id, paused: true}, %Workflow{}]} =
             Workflows.list_workflows(system_scope(), due: ~U[2026-10-13 06:00:00Z])
  end

  test "an invalid workflow is listed but never due", %{project: project} do
    sync_workflow_files(project, %{".rail/workflows/broken.yml" => "name: ["})

    assert {:ok, [%Workflow{definition: nil}]} = Workflows.list_workflows(system_scope(), [])
    assert {:ok, []} = Workflows.list_workflows(system_scope(), due: ~U[2027-01-01 00:00:00Z])
  end

  test "someone who is not an admin is refused" do
    assert {:error, :not_authorized} = Workflows.list_workflows(user_scope(), [])
  end
end
