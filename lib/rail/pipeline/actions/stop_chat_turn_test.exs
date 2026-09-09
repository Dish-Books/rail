defmodule Rail.Pipeline.Actions.StopChatTurnTest do
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

    %RoleRun{id: role_run_id} =
      create_test_role_run(%{
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

    _run =
      create_test_run(%{
        role_run_id: role_run_id,
        task_id: task_id,
        kind: :chat,
        status: :running
      })

    assert {:ok, %Task{active_chat_role_id: nil}} = Pipeline.stop_chat_turn(task.id)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :chat_stopped}}

    refreshed_task = Repo.get!(Task, task_id)
    assert refreshed_task.active_chat_role_id == nil

    refreshed_role_run = Repo.get!(RoleRun, role_run_id)
    assert refreshed_role_run.pending_chat == nil
    assert refreshed_role_run.chat_fingerprint_head_sha == nil
    assert refreshed_role_run.chat_fingerprint_dirty_digest == nil

    events = Runs.list_run_events(role_run_id)

    assert Enum.any?(events, fn %RunEvent{line: line} ->
             line == "[axis] Chat turn stopped by user."
           end)
  end

  test "cancel_pending_chat clears pending_chat and logs queued message cancelled", %{
    task: %Task{id: task_id} = task,
    role: %Role{id: role_id}
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    %RoleRun{id: role_run_id} =
      create_test_role_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-cancel",
        pending_chat: "Queued question to cancel"
      })

    assert {:ok, %RoleRun{pending_chat: nil}, %Task{}} =
             Pipeline.cancel_pending_chat(task.id, role_id)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :pending_chat_cancelled}}

    refreshed_role_run = Repo.get!(RoleRun, role_run_id)
    assert refreshed_role_run.pending_chat == nil

    events = Runs.list_run_events(role_run_id)

    assert Enum.any?(events, fn %RunEvent{line: line} ->
             line == "[axis] Queued message cancelled by user."
           end)

    assert {:ok, %RoleRun{pending_chat: nil}, %Task{}} =
             Pipeline.cancel_pending_chat(task.id, role_id)
  end

  test "stop_chat_turn with user scope, struct target, invalid target, and missing RoleRun", %{
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
