defmodule Rail.Runs.Schemas.RunEventTest do
  use Rail.DataCase, async: true

  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.RunEvent

  test "changeset/2 with valid attributes" do
    role_run_id = UXID.generate!(prefix: "rr")

    attrs = %{
      role_run_id: role_run_id,
      seq: 1,
      line: ~s({"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}})
    }

    changeset = RunEvent.changeset(%RunEvent{}, attrs)
    assert changeset.valid?

    assert get_change(changeset, :role_run_id) == role_run_id
    assert get_change(changeset, :seq) == 1
    assert get_change(changeset, :line) =~ "hello"
  end

  test "changeset/2 validates required fields" do
    changeset = RunEvent.changeset(%RunEvent{}, %{})
    refute changeset.valid?

    errors = errors_on(changeset)
    assert "can't be blank" in errors.role_run_id
    assert "can't be blank" in errors.seq
    assert "can't be blank" in errors.line
  end

  test "insert and retrieve run_event" do
    role_run =
      %RoleRun{}
      |> RoleRun.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, event} =
      %RunEvent{}
      |> RunEvent.changeset(%{
        role_run_id: role_run.id,
        seq: 1,
        line: "some raw line"
      })
      |> Repo.insert()

    assert is_binary(event.id) and byte_size(event.id) > 0
    assert event.role_run_id == role_run.id
    assert event.seq == 1
    assert event.line == "some raw line"
  end
end
