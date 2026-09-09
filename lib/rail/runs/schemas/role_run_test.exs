defmodule Rail.Runs.Schemas.RoleRunTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.TaskUsage
  alias Rail.Runs.Schemas.RoleRun

  test "factory/0 returns a valid struct" do
    role_run = RoleRun.factory()

    assert is_binary(role_run.task_id) and byte_size(role_run.task_id) > 0
    assert is_binary(role_run.role_id) and byte_size(role_run.role_id) > 0
    assert role_run.status == :running
    assert %DateTime{} = role_run.started_at
    assert role_run.attempts == 0
    assert role_run.attempt_log_lines == 0
    assert role_run.auto_retries == 0
    refute role_run.pruned
  end

  test "changeset/2 with valid attributes" do
    task_id = UXID.generate!(prefix: "tsk")
    role_id = UXID.generate!(prefix: "rol")
    now = DateTime.utc_now()

    attrs = %{
      task_id: task_id,
      role_id: role_id,
      status: :running,
      started_at: now,
      conversation_id: "conv-123",
      exit_code: 0,
      output: "Done",
      error: nil,
      usage: %{input_tokens: 100, output_tokens: 50},
      chat_usage: %{input_tokens: 20, output_tokens: 10}
    }

    changeset = RoleRun.changeset(%RoleRun{}, attrs)
    assert changeset.valid?

    assert get_change(changeset, :task_id) == task_id
    assert get_change(changeset, :role_id) == role_id
    assert get_change(changeset, :status) == :running
    assert get_change(changeset, :conversation_id) == "conv-123"

    usage_changeset = get_change(changeset, :usage)
    assert %TaskUsage{input_tokens: 100, output_tokens: 50} = apply_changes(usage_changeset)

    chat_usage_changeset = get_change(changeset, :chat_usage)
    assert %TaskUsage{input_tokens: 20, output_tokens: 10} = apply_changes(chat_usage_changeset)
  end

  test "changeset/2 validates required fields" do
    changeset = RoleRun.changeset(%RoleRun{}, %{})
    refute changeset.valid?

    errors = errors_on(changeset)
    assert "can't be blank" in errors.task_id
    assert "can't be blank" in errors.role_id
    assert "can't be blank" in errors.status
    assert "can't be blank" in errors.started_at
  end

  test "insert and retrieve role_run with embeds" do
    task_id = UXID.generate!(prefix: "tsk")
    role_id = UXID.generate!(prefix: "rol")
    now = DateTime.utc_now()

    {:ok, role_run} =
      %RoleRun{}
      |> RoleRun.changeset(%{
        task_id: task_id,
        role_id: role_id,
        status: :starting,
        started_at: now,
        usage: %{input_tokens: 120, output_tokens: 40}
      })
      |> Repo.insert()

    assert String.starts_with?(role_run.id, "rr_")
    assert role_run.usage.input_tokens == 120
    assert role_run.usage.output_tokens == 40
  end
end
