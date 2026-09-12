defmodule Rail.Pipeline.Actions.StartRebaseTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Runs
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Start Rebase Workspace",
        external_id: "lin_ws_start_rebase",
        token: "lin_api_token_start_rebase",
        webhook_secret: "whsec_start_rebase"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Start Rebase Project 8801",
        github_repo: "org/start-rebase-8801",
        github_installation_id: 8801,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_start_rebase_8801",
        linear_team_key: "P8801",
        default_branch: "main",
        clone_path: "/tmp/repos/start-rebase-8801",
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
      "id" => "lin_start_rebase_1",
      "identifier" => "SRB-1",
      "title" => "Start Rebase Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Start Rebase Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "refuses to start a rebase while the stage's run is still working", %{task: task, roles: roles} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :review})

    {:ok, _running} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:review].id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:error, :task_busy} = Pipeline.start_rebase(task)
  end

  test "starts a rebase, flags the detour, and broadcasts", %{
    project: _project,
    task: _task
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Start Rebase Project 8805",
        github_repo: "org/start-rebase-8805",
        github_installation_id: 8805,
        linear_team_id: "team_start_rebase_8805",
        linear_team_key: "P8805",
        default_branch: "main",
        clone_path: "/tmp/repos/start-rebase-8805",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_start_rebase_8807",
      "identifier" => "TSK-8807",
      "title" => "Task 8807"
    })

    {:ok, issue_8807} = Issues.capture_issue(system_scope(), project, "Task 8807")

    {:ok, %Task{id: _task_id} = task} = Pipeline.create_task(issue_8807, :product)

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(task, %{
        stage: :qa,
      })

    assert {:ok,
            %Task{
              is_rebasing: true,
            }} = Pipeline.start_rebase(task, [])

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :rebase_started}}
  end
end
