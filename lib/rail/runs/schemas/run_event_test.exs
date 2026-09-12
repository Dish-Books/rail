defmodule Rail.Runs.Schemas.RunEventTest do
  use Rail.DataCase, async: true

  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent

  test "changeset/2 with valid attributes" do
    run_id = UXID.generate!(prefix: "run")

    attrs = %{
      run_id: run_id,
      seq: 1,
      line: ~s({"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}})
    }

    changeset = RunEvent.changeset(%RunEvent{}, attrs)
    assert changeset.valid?

    assert get_change(changeset, :run_id) == run_id
    assert get_change(changeset, :seq) == 1
    assert get_change(changeset, :line) =~ "hello"
  end

  test "changeset/2 validates required fields" do
    changeset = RunEvent.changeset(%RunEvent{}, %{})
    refute changeset.valid?

    errors = errors_on(changeset)
    assert "can't be blank" in errors.run_id
    assert "can't be blank" in errors.seq
    assert "can't be blank" in errors.line
  end

  test "insert and retrieve run_event" do
    run =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, event} =
      %RunEvent{}
      |> RunEvent.changeset(%{
        run_id: run.id,
        seq: 1,
        line: "some raw line"
      })
      |> Repo.insert()

    assert is_binary(event.id) and byte_size(event.id) > 0
    assert event.run_id == run.id
    assert event.seq == 1
    assert event.line == "some raw line"
  end
end
