defmodule RailWeb.Live.RunConversationTest do
  use Rail.DataCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Roles
  alias RailTest.Mocks.Linear, as: LinearMock
  alias RailWeb.Live.RunConversation

  setup do
    scope = system_scope()

    {:ok, backend} = Rail.Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Conversation Project",
        github_repo: "org/conversation",
        github_installation_id: 22_101,
        linear_workspace: %{
          name: "Conversation Workspace",
          external_id: "lin_ws_conversation",
          token: "lin_api_token_conversation",
          webhook_secret: "whsec_conversation"
        },
        linear_team_id: "team_conversation",
        linear_team_key: "CNV",
        default_branch: "main",
        clone_path: "/tmp/repos/conversation",
        linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
      })

    roles =
      Map.new([:architect, :engineer], fn stage ->
        {:ok, role} =
          Roles.create_role(scope, project, %{
            backend_id: backend.id,
            stage: stage,
            name: String.capitalize(to_string(stage)),
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent.",
            icon_name: "pi-code"
          })

        {stage, role}
      end)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_conversation_1",
      "identifier" => "CNV-1",
      "title" => "Conversation Issue"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Conversation Issue"})
    {:ok, task} = Pipeline.create_task(issue, :product)
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})

    roles_map = Map.new(roles, fn {_stage, role} -> {role.id, role} end)

    %{project: project, task: task, roles: roles, roles_map: roles_map}
  end

  test "says so when no role has run the task", %{task: task, roles_map: roles_map} do
    html = render_component(RunConversation, id: "conv", task: task, runs: [], roles_map: roles_map)

    assert html =~ ~s(data-qa="conversation_empty_state")
    assert html =~ "No role has run this task yet."
  end

  test "offers a chip per run and describes the one being read", %{task: task, roles: roles, roles_map: roles_map} do
    {:ok, architect} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:architect].id,
        status: :finished,
        started_at: ~U[2026-09-09 09:00:00Z],
        completed_at: ~U[2026-09-09 09:05:00Z]
      })

    {:ok, engineer} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        conversation_id: "conv_engineer",
        started_at: ~U[2026-09-09 10:00:00Z]
      })

    html =
      render_component(RunConversation,
        id: "conv",
        task: task,
        runs: [architect, engineer],
        roles_map: roles_map
      )

    assert html =~ ~s(id="role-chip-#{architect.role_id}")
    assert html =~ ~s(id="role-chip-#{engineer.role_id}")

    # The most recent run is the one being read.
    assert html =~ "running"
    assert html =~ "conversation conv_engineer"
  end

  test "renders each kind of thing said in the conversation", %{task: task, roles: roles, roles_map: roles_map} do
    {:ok, architect} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:architect].id,
        status: :finished,
        started_at: ~U[2026-09-09 09:00:00Z]
      })

    {:ok, engineer} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        conversation_id: "conv_engineer",
        started_at: ~U[2026-09-09 10:00:00Z]
      })

    Enum.each(
      [
        "[human] Please implement the OAuth callback handler",
        "[run] Runner started execution",
        "I will start by reviewing the router.",
        "[tool read_file] lib/rail_web/router.ex",
        "[tool read_file] lib/rail_web/user_auth.ex",
        "Follow the schema plan closely.",
        "[rail] Automated check completed"
      ],
      &Pipeline.append_run_event(engineer, &1)
    )

    html =
      render_component(RunConversation,
        id: "conv",
        task: task,
        runs: [architect, engineer],
        roles_map: roles_map
      )

    assert html =~ ~s(data-qa="human-bubble")
    assert html =~ "Please implement the OAuth callback handler"
    assert html =~ ~s(data-qa="role-bubble")
    assert html =~ "I will start by reviewing the router."
    assert html =~ ~s(data-qa="activity-tile")
    assert html =~ "Tool activity (2 steps)"
    refute html =~ ~s(data-qa="activity-content")
    assert html =~ ~s(data-qa="rail-event")
    assert html =~ ~s(data-qa="system-event")
  end

  test "the composer says the agent is thinking, and offers to stop it", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        conversation_id: "conv_thinking",
        started_at: DateTime.utc_now()
      })

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ ~s(id="thinking-banner")
    assert html =~ ~s(id="stop-run")
    refute html =~ ~s(id="queued-banner")
  end

  test "a message waiting on a working agent stacks under the thinking banner", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        conversation_id: "conv_queued",
        pending_chat: "Please add a test",
        started_at: DateTime.utc_now()
      })

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ ~s(id="thinking-banner")
    assert html =~ ~s(id="queued-banner")
    assert html =~ ~s(id="send-queued-now")
    assert html =~ "Please add a test"
  end

  test "a run with no conversation cannot be chatted with", %{task: task, roles: roles, roles_map: roles_map} do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ ~s(id="unavailable-banner")
    assert html =~ "has not started a conversation"
  end
end
