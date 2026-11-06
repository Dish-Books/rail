defmodule Rail.Workflows.Actions.RunWorkflowNowTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Workflows
  alias Rail.Workflows.Schemas.Workflow
  alias Rail.Workflows.Schemas.WorkflowDefinition
  alias Rail.Workflows.Workers.StartWorkflowTask

  setup %{project: project} do
    workflow =
      %Workflow{
        project_id: project.id,
        path: ".rail/workflows/dependency-updates.yml",
        definition: %WorkflowDefinition{
          name: "Dependency updates",
          schedule: "0 9 * * 1",
          instructions: "Update the dependencies."
        },
        next_run_at: ~U[2026-10-12 09:00:00Z]
      }
      |> Repo.insert!()
      |> Repo.preload(:project)

    stub(DateTime, :utc_now, fn -> ~U[2026-10-14 10:00:00.000000Z] end)

    %{workflow: workflow}
  end

  test "Run now on a paused workflow opens one issue dated the day it was pressed, and the next start stays", %{
    workflow: %{id: workflow_id} = workflow
  } do
    {:ok, paused} = Workflows.set_workflow_paused(system_scope(), workflow, true)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_TST-84", "identifier" => "TST-84", "title" => "Dependency updates 2026-10-14"}
          }
        }
      })
    end)

    assert {:ok,
            %Issue{identifier: "TST-84", title: "Dependency updates 2026-10-14", workflow_id: ^workflow_id, id: issue_id}} =
             Workflows.run_workflow_now(system_scope(), paused)

    assert %Workflow{paused: true, next_run_at: ~U[2026-10-12 09:00:00Z]} = Repo.get!(Workflow, workflow_id)

    # No second tracker request is expected, so one would raise.
    assert {:error, {:unfinished, %Issue{id: ^issue_id}}} = Workflows.run_workflow_now(system_scope(), paused)
    assert [%Oban.Job{args: %{"issue_id" => ^issue_id}}] = all_enqueued(worker: StartWorkflowTask)
  end

  test "two presses racing from separate processes open one issue between them", %{
    workflow: %{id: workflow_id} = workflow
  } do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_TST-85", "identifier" => "TST-85", "title" => "Dependency updates 2026-10-14"}
          }
        }
      })
    end)

    presses = for _tab <- 1..2, do: Elixir.Task.async(fn -> Workflows.run_workflow_now(system_scope(), workflow) end)

    assert [{:ok, %Issue{id: issue_id}}, {:error, {:unfinished, %Issue{id: issue_id}}}] =
             Enum.sort_by(Elixir.Task.await_many(presses), &elem(&1, 0), :desc)

    assert [%Issue{id: ^issue_id}] = Repo.all(from(i in Issue, where: i.workflow_id == ^workflow_id))
    assert [%Oban.Job{args: %{"issue_id" => ^issue_id}}] = all_enqueued(worker: StartWorkflowTask)
  end

  test "a workflow on an inactive project opens nothing and says so" do
    {:ok, inactive} =
      Projects.create_project(system_scope(), %{
        name: "Ledger",
        github_repo: "example/ledger",
        github_installation_id: 1,
        default_branch: "main",
        key: "LED",
        clone_path: "/tmp/repos/ledger",
        active: false
      })

    workflow =
      %Workflow{
        project_id: inactive.id,
        path: ".rail/workflows/changelog.yml",
        definition: %WorkflowDefinition{name: "Changelog", schedule: "0 9 * * 1", instructions: "Draft the changelog."},
        next_run_at: ~U[2026-10-12 09:00:00Z]
      }
      |> Repo.insert!()
      |> Repo.preload(:project)

    assert {:error, :project_inactive} = Workflows.run_workflow_now(system_scope(), workflow)
  end

  test "an invalid workflow opens nothing", %{project: project} do
    workflow =
      %Workflow{project_id: project.id, path: ".rail/workflows/broken.yml"}
      |> Repo.insert!()
      |> Repo.preload(:project)

    assert {:error, :invalid} = Workflows.run_workflow_now(system_scope(), workflow)
  end

  test "a workflow whose file is gone opens nothing", %{workflow: %{id: workflow_id} = stale} do
    Repo.update_all(from(w in Workflow, where: w.id == ^workflow_id), set: [removed_at: ~U[2026-10-14 09:00:00.000000Z]])

    assert {:error, :invalid} = Workflows.run_workflow_now(system_scope(), stale)
  end

  test "someone who is not an admin is refused", %{workflow: workflow} do
    assert {:error, :not_authorized} = Workflows.run_workflow_now(user_scope(), workflow)
  end
end
