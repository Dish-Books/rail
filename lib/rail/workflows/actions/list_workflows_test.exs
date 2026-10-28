defmodule Rail.Workflows.Actions.ListWorkflowsTest do
  use Rail.DataCase, async: true

  alias Rail.Projects.Schemas.Project
  alias Rail.Workflows
  alias Rail.Workflows.Schemas.Workflow
  alias Rail.Workflows.Schemas.WorkflowDefinition

  test "lists workflows by project name, then path, with their project", %{project: project, github_project: github} do
    for {project_id, path} <- [
          {project.id, ".rail/workflows/sweep.yml"},
          {project.id, ".rail/workflows/audit.yml"},
          {github.id, ".rail/workflows/deps.yml"}
        ] do
      Repo.insert!(%Workflow{
        project_id: project_id,
        path: path,
        definition: %WorkflowDefinition{
          name: "Dependency updates",
          schedule: "0 9 * * 1",
          instructions: "Update the dependencies."
        },
        next_run_at: ~U[2026-10-12 09:00:00Z]
      })
    end

    # A file gone from the branch is not listed.
    Repo.insert!(%Workflow{
      project_id: project.id,
      path: ".rail/workflows/gone.yml",
      removed_at: ~U[2026-10-11 08:00:00.000000Z]
    })

    assert {:ok,
            [
              %Workflow{path: ".rail/workflows/deps.yml", project: %Project{name: "Test GitHub Project"}},
              %Workflow{path: ".rail/workflows/audit.yml", project: %Project{name: "Test Project"}},
              %Workflow{path: ".rail/workflows/sweep.yml"}
            ]} = Workflows.list_workflows(user_scope(admin: true), [])
  end

  test "the due filter keeps paused workflows and leaves out those due later", %{project: project} do
    %Workflow{id: daily_id} =
      daily =
      %Workflow{
        project_id: project.id,
        path: ".rail/workflows/daily.yml",
        definition: %WorkflowDefinition{name: "Daily", schedule: "0 6 * * *", instructions: "Sweep the flaky tests."},
        next_run_at: ~U[2026-10-13 06:00:00Z]
      }
      |> Repo.insert!()
      |> Repo.preload(:project)

    Repo.insert!(%Workflow{
      project_id: project.id,
      path: ".rail/workflows/weekly.yml",
      definition: %WorkflowDefinition{name: "Weekly", schedule: "0 9 * * 1", instructions: "Update the dependencies."},
      next_run_at: ~U[2026-10-12 09:00:00Z]
    })

    {:ok, _paused} = Workflows.set_workflow_paused(system_scope(), daily, true)

    # 2026-10-12 is a Monday: daily next runs Tuesday at 06:00, weekly Monday at 09:00.
    assert {:ok, []} = Workflows.list_workflows(system_scope(), due: ~U[2026-10-12 08:59:00Z])

    assert {:ok, [%Workflow{path: ".rail/workflows/weekly.yml"}]} =
             Workflows.list_workflows(system_scope(), due: ~U[2026-10-12 09:00:00Z])

    assert {:ok, [%Workflow{id: ^daily_id, paused: true}, %Workflow{}]} =
             Workflows.list_workflows(system_scope(), due: ~U[2026-10-13 06:00:00Z])
  end

  test "an invalid workflow is listed but never due", %{project: project} do
    Repo.insert!(%Workflow{project_id: project.id, path: ".rail/workflows/broken.yml"})

    assert {:ok, [%Workflow{definition: nil}]} = Workflows.list_workflows(system_scope(), [])
    assert {:ok, []} = Workflows.list_workflows(system_scope(), due: ~U[2027-01-01 00:00:00Z])
  end

  test "someone who is not an admin is refused" do
    assert {:error, :not_authorized} = Workflows.list_workflows(user_scope(), [])
  end
end
