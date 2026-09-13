defmodule Rail.Pipeline.Utils.EngineerRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.EngineerRunFinished

  alias Rail.Issues
  alias Rail.Pipeline
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
        name: "Settle Engineer Workspace",
        external_id: "lin_ws_settle_engineer",
        token: "lin_api_token_settle_engineer",
        webhook_secret: "whsec_settle_engineer"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Settle Engineer Project 14604",
        github_repo: "org/settle-engineer-14604",
        github_installation_id: 14_604,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_settle_engineer_14604",
        linear_team_key: "P14604",
        default_branch: "main",
        clone_path: "/tmp/repos/settle-engineer-14604",
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
      "id" => "lin_settle_engineer_1",
      "identifier" => "S14604-1",
      "title" => "Settle Engineer Issue"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Settle Engineer Issue"})

    {:ok, task} = Pipeline.create_task(issue, :product)

    # These tests exercise stage transitions, not Linear publishing.
    {:ok, task} = Pipeline.update_task(task, %{issue_id: nil})

    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, [:task, :role])

    %{backend: backend, project: project, issue: issue, task: task, roles: roles, run: run}
  end

  test "a finished engineer hands the worktree to review", %{task: task, run: run} do
    assert %Run{} = engineer_run_finished(run, [])
    assert %Task{stage: :review} = Repo.get!(Task, task.id)
  end

  test "the review run is started fresh so it can conclude again", %{task: task, run: run, roles: roles} do
    {:ok, review_run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:review].id,
        conversation_id: "sess_review",
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.utc_now()
      })

    assert %Run{} = engineer_run_finished(run, [])
    assert %Run{stage_outcome: :in_progress} = Repo.reload!(review_run)
  end
end
