defmodule Rail.Pipeline.Utils.RebaseRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.RebaseRunFinished

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
        name: "Settle Rebase Workspace",
        external_id: "lin_ws_settle_rebase",
        token: "lin_api_token_settle_rebase",
        webhook_secret: "whsec_settle_rebase"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Settle Rebase Project 14609",
        github_repo: "org/settle-rebase-14609",
        github_installation_id: 14_609,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_settle_rebase_14609",
        linear_team_key: "P14609",
        default_branch: "main",
        clone_path: "/tmp/repos/settle-rebase-14609",
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
      "id" => "lin_settle_rebase_1",
      "identifier" => "S14609-1",
      "title" => "Settle Rebase Issue"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Settle Rebase Issue"})

    {:ok, task} = Pipeline.create_task(issue, :product)

    # These tests exercise stage transitions, not Linear publishing.
    {:ok, task} = Pipeline.update_task(task, %{issue_id: nil})

    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, is_rebasing: true})

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

  test "a landed rebase clears the detour and leaves the stage where it was", %{task: task, run: run} do
    run = %{run | exit_code: 0}

    assert %Run{} = rebase_run_finished(run, [])
    assert %Task{stage: :engineer, is_rebasing: false} = Repo.get!(Task, task.id)
  end

  test "a rebase that failed stays a rebase, so it can be run again", %{task: task, run: run} do
    run = %{run | exit_code: 1}

    assert %Run{} = rebase_run_finished(run, [])
    assert %Task{is_rebasing: true} = Repo.get!(Task, task.id)
  end

  test "landing a rebase clears the detour even for a task that was conflicting", %{task: task, run: run} do
    {:ok, _task} = Pipeline.update_task(task, %{mergeability: :conflicting})
    run = %{run | exit_code: 0, task: Repo.get!(Task, task.id)}

    assert %Run{task: %Task{is_rebasing: false}} = rebase_run_finished(run, [])
    assert %Task{is_rebasing: false} = Repo.get!(Task, task.id)
  end
end
