defmodule Rail.Pipeline.Utils.ArchitectRunFinishedTest do
  use Rail.DataCase, async: true

  import Ecto.Query
  import Rail.Pipeline.Utils.ArchitectRunFinished

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Settle Architect Workspace",
        external_id: "lin_ws_settle_architect",
        token: "lin_api_token_settle_architect",
        webhook_secret: "whsec_settle_architect"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Settle Architect Project 14603",
        github_repo: "org/settle-architect-14603",
        github_installation_id: 14_603,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_settle_architect_14603",
        linear_team_key: "P14603",
        default_branch: "main",
        clone_path: "/tmp/repos/settle-architect-14603",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    roles =
      Map.new([:product, :design, :architect, :engineer, :review, :qa, :qa_lead, :demo], fn stage ->
        {:ok, role} =
          Roles.create_role(scope, project, %{
            backend_id: backend.id,
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_settle_architect_1",
      "identifier" => "S14603-1",
      "title" => "Settle Architect Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Settle Architect Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    # These tests exercise stage transitions, not Linear publishing.
    {:ok, task} = Pipeline.update_task(task, %{issue_id: nil})

    {:ok, task} = Pipeline.update_task(task, %{stage: :architect})

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:architect].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, [:task, :role])

    %{backend: backend, project: project, issue: issue, task: task, roles: roles, run: run}
  end

  test "captures the plan and leaves the task for a human to approve", %{task: task, run: run} do
    File.mkdir_p!(task.scratch_path)
    File.write!(Path.join(task.scratch_path, "plan.md"), "# Plan\n\nDo the thing.")

    assert %Run{error: nil} = architect_run_finished(run, [])
    assert Repo.exists?(from p in Plan, where: p.task_id == ^task.id)
    assert %Task{stage: :architect} = Repo.get!(Task, task.id)
  end

  test "an architect that wrote no plan records that on its run", %{task: task, run: run} do
    assert %Run{error: error} = architect_run_finished(run, [])
    assert error =~ "without writing a plan file"
    refute Repo.exists?(from p in Plan, where: p.task_id == ^task.id)
  end
end
