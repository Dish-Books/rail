defmodule Rail.Pipeline.Actions.CancelPendingChatTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.RunEvent
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Cancel Chat Workspace",
        external_id: "lin_ws_cancel_chat",
        token: "lin_api_token_cancel_chat",
        webhook_secret: "whsec_cancel_chat"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Cancel Chat Project 8201",
        github_repo: "org/cancel-chat-8201",
        github_installation_id: 8201,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_cancel_chat_8201",
        linear_team_key: "P8201",
        default_branch: "main",
        clone_path: "/tmp/repos/cancel-chat-8201",
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
      "id" => "lin_cancel_chat_1",
      "identifier" => "CPC-1",
      "title" => "Cancel Chat Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Cancel Chat Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  setup %{project: project, roles: roles} do
    {:ok, role} =
      Roles.update_role(system_scope(), roles[:engineer], %{
        cli_backend: :claude,
        model: "claude-3-7-sonnet"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_cancel_chat_8204",
      "identifier" => "TSK-8204",
      "title" => "Task 8204"
    })

    {:ok, issue_8204} = Issues.capture_issue(system_scope(), project, "Task 8204")

    {:ok, task} = Pipeline.create_task(issue_8204, :product)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :queued
      })

    %{project: project, role: role, task: task}
  end

  test "returns not_authorized for invalid scope", %{task: task, role: role} do
    assert {:error, :not_authorized} =
             Pipeline.cancel_pending_chat(%Scope{system: false, user: nil}, task.id, role.id)
  end

  test "returns not_found when task does not exist", %{role: role} do
    assert {:error, :not_found} =
             Pipeline.cancel_pending_chat("tsk_000000000000000000000000", role.id)

    assert {:error, :not_found} =
             Pipeline.cancel_pending_chat(12_345, role.id)
  end

  test "returns not_found when role run does not exist", %{task: task} do
    assert {:error, :not_found} =
             Pipeline.cancel_pending_chat(task.id, "rol_nonexistent")
  end

  test "returns ok unchanged when role run has no pending_chat", %{task: task, role: role} do
    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-no-pending",
        pending_chat: nil
      })

    user_scope = %Scope{system: false, user: %{id: "usr_1"}}

    assert {:ok, %RoleRun{pending_chat: nil}, %Task{}} =
             Pipeline.cancel_pending_chat(user_scope, task, role.id)

    assert Repo.get!(RoleRun, role_run.id).pending_chat == nil
  end

  test "clears pending_chat, logs event, and broadcasts pipeline_changed", %{
    task: %Task{id: task_id} = task,
    role: %Role{id: role_id}
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-cancel",
        pending_chat: "Queued question to be cancelled"
      })

    assert {:ok, %RoleRun{pending_chat: nil}, %Task{}} =
             Pipeline.cancel_pending_chat(task.id, role_id)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :pending_chat_cancelled}}

    assert Repo.get!(RoleRun, role_run.id).pending_chat == nil

    events = Runs.list_run_events(role_run.id)

    assert Enum.any?(events, fn %RunEvent{line: line} ->
             line == "[rail] Queued message cancelled by user."
           end)
  end
end
