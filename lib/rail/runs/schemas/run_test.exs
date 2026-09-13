defmodule Rail.Runs.Schemas.RunTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.TaskUsage
  alias Rail.Runs.Schemas.Run

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
      usage: %{input_tokens: 100, output_tokens: 50}
    }

    changeset = Run.changeset(%Run{}, attrs)
    assert changeset.valid?

    assert get_change(changeset, :task_id) == task_id
    assert get_change(changeset, :role_id) == role_id
    assert get_change(changeset, :status) == :running
    assert get_change(changeset, :conversation_id) == "conv-123"

    usage_changeset = get_change(changeset, :usage)
    assert %TaskUsage{input_tokens: 100, output_tokens: 50} = apply_changes(usage_changeset)
  end

  test "changeset/2 validates required fields" do
    changeset = Run.changeset(%Run{}, %{})
    refute changeset.valid?

    errors = errors_on(changeset)
    assert "can't be blank" in errors.task_id
    assert "can't be blank" in errors.role_id
    assert "can't be blank" in errors.status
    assert "can't be blank" in errors.started_at
  end

  test "changeset/2 validates status enum" do
    changeset = Run.changeset(%Run{}, %{status: "invalid_status"})
    refute changeset.valid?
    assert "is invalid" in errors_on(changeset).status
  end

  test "statuses/0 returns all allowed statuses" do
    statuses = Run.statuses()
    assert :starting in statuses
    assert :running in statuses
    assert :finished in statuses
    assert :adopted_dead in statuses
    assert :blocked_on_input in statuses
  end

  test "insert and retrieve run with embeds" do
    task_id = UXID.generate!(prefix: "tsk")
    role_id = UXID.generate!(prefix: "rol")
    now = DateTime.utc_now()

    {:ok, run} =
      %Run{}
      |> Run.changeset(%{
        task_id: task_id,
        role_id: role_id,
        status: :starting,
        started_at: now,
        usage: %{input_tokens: 120, output_tokens: 40}
      })
      |> Repo.insert()

    assert String.starts_with?(run.id, "run_")
    assert run.usage.input_tokens == 120
    assert run.usage.output_tokens == 40
  end

  test "has_started?/1 and can_chat?/1 logic" do
    unstarted = %Run{started_at: nil, conversation_id: nil}
    refute Run.has_started?(unstarted)
    refute Run.can_chat?(unstarted)

    started_no_conv = %Run{started_at: DateTime.utc_now(), conversation_id: nil}
    assert Run.has_started?(started_no_conv)
    refute Run.can_chat?(started_no_conv)

    started_empty_conv = %Run{started_at: DateTime.utc_now(), conversation_id: "  "}
    assert Run.has_started?(started_empty_conv)
    refute Run.can_chat?(started_empty_conv)

    started_with_conv = %Run{started_at: DateTime.utc_now(), conversation_id: "sess-123"}
    assert Run.has_started?(started_with_conv)
    assert Run.can_chat?(started_with_conv)

    # A conversation is not a start: a run that never ran cannot be resumed.
    conv_without_start = %Run{started_at: nil, conversation_id: "sess-456"}
    refute Run.has_started?(conv_without_start)
    refute Run.can_chat?(conv_without_start)

    refute Run.has_started?(nil)
    refute Run.can_chat?(nil)
  end
end
