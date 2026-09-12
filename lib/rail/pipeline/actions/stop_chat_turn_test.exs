defmodule Rail.Pipeline.Actions.StopChatTurnTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Stop Chat Workspace",
        external_id: "lin_ws_stop_chat",
        token: "lin_api_token_stop_chat",
        webhook_secret: "whsec_stop_chat"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Stop Chat Project 8301",
        github_repo: "org/stop-chat-8301",
        github_installation_id: 8301,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_stop_chat_8301",
        linear_team_key: "P8301",
        default_branch: "main",
        clone_path: "/tmp/repos/stop-chat-8301",
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
      "id" => "lin_stop_chat_1",
      "identifier" => "SCT-1",
      "title" => "Stop Chat Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Stop Chat Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{backend: backend, project: project, issue: issue, task: task, roles: roles}
  end

  setup %{backend: backend, project: project, roles: roles} do
    {:ok, role} =
      Roles.update_role(system_scope(), roles[:engineer], %{
        backend_id: backend.id,
        model: "claude-3-7-sonnet"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_stop_chat_8304",
      "identifier" => "TSK-8304",
      "title" => "Task 8304"
    })

    {:ok, issue_8304} = Issues.capture_issue(system_scope(), project, "Task 8304")

    {:ok, task} = Pipeline.create_task(issue_8304, :product)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :queued
      })

    %{project: project, role: role, task: task}
  end

  test "stop_chat_turn scope authorization and not_found", %{role: role, task: task} do
    assert {:error, :not_authorized} =
             Pipeline.stop_chat_turn(%Scope{system: false, user: nil}, task.id)

    assert {:error, :not_found} =
             Pipeline.stop_chat_turn("tsk_000000000000000000000000")

    assert {:ok, %Task{active_chat_role_id: nil}} = Pipeline.stop_chat_turn(task.id)

    assert {:error, :not_authorized} =
             Pipeline.cancel_pending_chat(%Scope{system: false, user: nil}, task.id, role.id)

    assert {:error, :not_found} =
             Pipeline.cancel_pending_chat("tsk_000000000000000000000000", role.id)

    assert {:error, :not_found} =
             Pipeline.cancel_pending_chat(task.id, "rol_nonexistent")
  end

  test "stop_chat_turn terminates running chat run, clears active_chat_role_id, and appends stop log", %{
    task: %Task{id: task_id} = task,
    role: %Role{id: role_id}
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, %Run{id: run_id}} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-stop",
        pending_chat: "Message to stop",
        chat_fingerprint_head_sha: "head123",
        chat_fingerprint_dirty_digest: "digest123"
      })

    {:ok, task} = task |> Task.changeset(%{active_chat_role_id: role_id}) |> Repo.update()

    %OsProcess{}
    |> OsProcess.changeset(%{
      run_id: run_id,
      task_id: task_id,
      kind: :chat,
      stream_path: "/tmp/stop_chat_turn/#{run_id}.ndjson",
      node: to_string(Node.self()),
      status: :running,
      started_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert {:ok, %Task{active_chat_role_id: nil}} = Pipeline.stop_chat_turn(task.id)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :chat_stopped}}

    refreshed_task = Repo.get!(Task, task_id)
    assert refreshed_task.active_chat_role_id == nil

    refreshed_run = Repo.get!(Run, run_id)
    assert refreshed_run.pending_chat == nil
    assert refreshed_run.chat_fingerprint_head_sha == nil
    assert refreshed_run.chat_fingerprint_dirty_digest == nil

    events = Runs.list_run_events(run_id)

    assert Enum.any?(events, fn %RunEvent{line: line} ->
             line == "[rail] Chat turn stopped by user."
           end)
  end

  test "cancel_pending_chat clears pending_chat and logs queued message cancelled", %{
    task: %Task{id: task_id} = task,
    role: %Role{id: role_id}
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, %Run{id: run_id}} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-cancel",
        pending_chat: "Queued question to cancel"
      })

    assert {:ok, %Run{pending_chat: nil}, %Task{}} =
             Pipeline.cancel_pending_chat(task.id, role_id)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :pending_chat_cancelled}}

    refreshed_run = Repo.get!(Run, run_id)
    assert refreshed_run.pending_chat == nil

    events = Runs.list_run_events(run_id)

    assert Enum.any?(events, fn %RunEvent{line: line} ->
             line == "[rail] Queued message cancelled by user."
           end)

    assert {:ok, %Run{pending_chat: nil}, %Task{}} =
             Pipeline.cancel_pending_chat(task.id, role_id)
  end

  test "stop_chat_turn with user scope, struct target, invalid target, and missing Run", %{
    task: task,
    role: role
  } do
    user_scope = %Scope{system: false, user: %{id: "usr_1"}}

    assert {:ok, %Task{active_chat_role_id: nil}} =
             Pipeline.stop_chat_turn(user_scope, task)

    assert {:error, :not_found} =
             Pipeline.stop_chat_turn(12_345)

    {:ok, busy_task} =
      task
      |> Task.changeset(%{active_chat_role_id: role.id})
      |> Repo.update()

    assert {:ok, %Task{active_chat_role_id: nil}} =
             Pipeline.stop_chat_turn(busy_task)
  end
end
