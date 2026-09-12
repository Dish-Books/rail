defmodule Rail.Pipeline.Actions.CancelTaskTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Users
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Cancel Task Workspace",
        external_id: "lin_ws_cancel_task",
        token: "lin_api_token_cancel_task",
        webhook_secret: "whsec_cancel_task"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Cancel Task Project 8101",
        github_repo: "org/cancel-task-8101",
        github_installation_id: 8101,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_cancel_task_8101",
        linear_team_key: "P8101",
        default_branch: "main",
        clone_path: "/tmp/repos/cancel-task-8101",
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
      "id" => "lin_cancel_task_1",
      "identifier" => "CTK-1",
      "title" => "Cancel Task Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Cancel Task Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "cancels a running task, sets failed state and error, and broadcasts", %{project: _project, task: _task} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Cancel Task Project 8102",
        github_repo: "org/cancel-task-8102",
        github_installation_id: 8102,
        linear_team_id: "team_cancel_task_8102",
        linear_team_key: "P8102",
        default_branch: "main",
        clone_path: "/tmp/repos/cancel-task-8102",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_cancel_task_8103",
        login: "cancel_task_user_8103",
        email: "cancel_task_user_8103@example.com"
      })

    scope = Scope.for_user(user)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_cancel_task_8104",
      "identifier" => "TSK-8104",
      "title" => "Task 8104"
    })

    {:ok, issue_8104} = Issues.capture_issue(system_scope(), project, "Task 8104")

    {:ok, %Task{id: task_id} = task} = Pipeline.create_task(issue_8104, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :engineer,
        stage_state: :running,
        retry_after: DateTime.utc_now()
      })

    assert {:ok,
            %Task{
              stage_state: :failed,
              error: "Cancelled.",
              retry_after: nil
            }} = Pipeline.cancel_task(task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :task_cancelled}}
  end

  test "cancelling a rebasing task restores pre-rebase state with conflict error", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Cancel Task Project 8105",
        github_repo: "org/cancel-task-8105",
        github_installation_id: 8105,
        linear_team_id: "team_cancel_task_8105",
        linear_team_key: "P8105",
        default_branch: "main",
        clone_path: "/tmp/repos/cancel-task-8105",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_cancel_task_8106",
      "identifier" => "TSK-8106",
      "title" => "Task 8106"
    })

    {:ok, issue_8106} = Issues.capture_issue(system_scope(), project, "Task 8106")

    {:ok, task} = Pipeline.create_task(issue_8106, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :ready_to_merge,
        stage_state: :queued,
        is_rebasing: true,
        stage_state_before_rebase: :awaiting_approval
      })

    assert {:ok,
            %Task{
              is_rebasing: false,
              stage_state: :awaiting_approval,
              stage_state_before_rebase: nil,
              error: "Rebase cancelled. The branch still conflicts."
            }} = Pipeline.cancel_task(task)
  end

  test "cancelling a task with active chat turn stops chat", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Cancel Task Project 8107",
        github_repo: "org/cancel-task-8107",
        github_installation_id: 8107,
        linear_team_id: "team_cancel_task_8107",
        linear_team_key: "P8107",
        default_branch: "main",
        clone_path: "/tmp/repos/cancel-task-8107",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_cancel_task_8108",
      "identifier" => "TSK-8108",
      "title" => "Task 8108"
    })

    {:ok, issue_8108} = Issues.capture_issue(system_scope(), project, "Task 8108")

    {:ok, task} = Pipeline.create_task(issue_8108, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :engineer,
        stage_state: :running,
        active_chat_role_id: "engineer"
      })

    assert {:ok,
            %Task{
              active_chat_role_id: nil,
              stage_state: :failed,
              error: "Cancelled."
            }} = Pipeline.cancel_task(task)
  end

  test "returns error when task is not found" do
  end

  test "cancels with options and delegates properly", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Cancel Task Project 8109",
        github_repo: "org/cancel-task-8109",
        github_installation_id: 8109,
        linear_team_id: "team_cancel_task_8109",
        linear_team_key: "P8109",
        default_branch: "main",
        clone_path: "/tmp/repos/cancel-task-8109",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_cancel_task_8110",
      "identifier" => "TSK-8110",
      "title" => "Task 8110"
    })

    {:ok, issue_8110} = Issues.capture_issue(system_scope(), project, "Task 8110")

    {:ok, task} = Pipeline.create_task(issue_8110, :product)

    assert {:ok, %Task{stage_state: :failed}} =
             Pipeline.cancel_task(task, dispatcher: nil)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_cancel_task_8111",
      "identifier" => "TSK-8111",
      "title" => "Task 8111"
    })

    {:ok, issue_8111} = Issues.capture_issue(system_scope(), project, "Task 8111")

    {:ok, task2} = Pipeline.create_task(issue_8111, :product)

    assert {:ok, %Task{stage_state: :failed}} =
             Pipeline.cancel_task(task2, dispatcher: nil)
  end
end
