defmodule Rail.Pipeline.Actions.StartRebaseTest do
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

    LinearMock.mock_update_issue_success(%{"id" => "lin_start_rebase_1"})

    {:ok, task} = Pipeline.create_task(issue)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "refuses to start rebase when task is busy (running or active chat)", %{project: _project} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Start Rebase Project 8802",
        github_repo: "org/start-rebase-8802",
        github_installation_id: 8802,
        linear_team_id: "team_start_rebase_8802",
        linear_team_key: "P8802",
        clone_path: "/tmp/repos/start-rebase-8802",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_start_rebase_8803",
      "identifier" => "TSK-8803",
      "title" => "Task 8803"
    })

    {:ok, issue_8803} = Issues.capture_issue(system_scope(), project, "Task 8803")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_start_rebase_8803"})

    {:ok, task_running} = Pipeline.create_task(issue_8803)

    {:ok, task_running} =
      Pipeline.update_task(system_scope(), task_running.id, %{
        stage: :review,
        stage_state: :running
      })

    assert {:error, :task_busy} = Pipeline.start_rebase(task_running)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_start_rebase_8804",
      "identifier" => "TSK-8804",
      "title" => "Task 8804"
    })

    {:ok, issue_8804} = Issues.capture_issue(system_scope(), project, "Task 8804")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_start_rebase_8804"})

    {:ok, task_chatting} = Pipeline.create_task(issue_8804)

    {:ok, task_chatting} =
      Pipeline.update_task(system_scope(), task_chatting.id, %{
        stage: :review,
        stage_state: :awaiting_approval,
        active_chat_role_id: "reviewer"
      })

    assert {:error, :task_busy} = Pipeline.start_rebase(task_chatting)
  end

  test "starts rebase, queues task, preserves stage_state_before_rebase, and broadcasts", %{
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
        clone_path: "/tmp/repos/start-rebase-8805",
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
        github_id: "gh_start_rebase_8806",
        login: "start_rebase_user_8806",
        email: "start_rebase_user_8806@example.com"
      })

    scope = Scope.for_user(user)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_start_rebase_8807",
      "identifier" => "TSK-8807",
      "title" => "Task 8807"
    })

    {:ok, issue_8807} = Issues.capture_issue(system_scope(), project, "Task 8807")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_start_rebase_8807"})

    {:ok, %Task{id: _task_id} = task} = Pipeline.create_task(issue_8807)

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa,
        stage_state: :awaiting_approval,
        error: "Some previous error",
        retry_after: DateTime.utc_now()
      })

    assert {:ok,
            %Task{
              is_rebasing: true,
              stage_state_before_rebase: :awaiting_approval,
              stage_state: :queued,
              error: nil,
              retry_after: nil
            }} = Pipeline.start_rebase(scope, task, [])

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :rebase_started}}
  end

  test "returns error when scope is unauthorized" do
    assert {:error, :not_authorized} = Pipeline.start_rebase(:invalid_scope, "tsk_123")
  end

  test "returns error when task is not found" do
    assert {:error, :not_found} = Pipeline.start_rebase("tsk_nonexistent")
    assert {:error, :not_found} = Pipeline.start_rebase(123)
  end

  test "accepts nil scope and task with opts", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Start Rebase Project 8808",
        github_repo: "org/start-rebase-8808",
        github_installation_id: 8808,
        linear_team_id: "team_start_rebase_8808",
        linear_team_key: "P8808",
        clone_path: "/tmp/repos/start-rebase-8808",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_start_rebase_8809",
      "identifier" => "TSK-8809",
      "title" => "Task 8809"
    })

    {:ok, issue_8809} = Issues.capture_issue(system_scope(), project, "Task 8809")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_start_rebase_8809"})

    {:ok, task} = Pipeline.create_task(issue_8809)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{is_rebasing: true}} = Pipeline.start_rebase(nil, task)
    assert {:ok, %Task{is_rebasing: true}} = Pipeline.start_rebase(task.id, dispatcher: :test_dispatcher)
  end
end
