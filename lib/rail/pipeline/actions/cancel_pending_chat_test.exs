defmodule Rail.Pipeline.Actions.CancelPendingChatTest do
  use Rail.DataCase, async: false

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.RunEvent
  alias Rail.Scope

  setup do
    project = create_test_project()

    role =
      create_test_role(%{
        project_id: project.id,
        stage: :engineer,
        cli_backend: :claude,
        model: "claude-3-7-sonnet"
      })

    task =
      create_test_task(%{
        project_id: project.id,
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
    role_run =
      create_test_role_run(%{
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

    role_run =
      create_test_role_run(%{
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
