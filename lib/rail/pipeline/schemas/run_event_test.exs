defmodule Rail.Pipeline.Schemas.RunEventTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent

  test "changeset/2 with valid attributes" do
    run_id = UXID.generate!(prefix: "run")

    os_process_id = UXID.generate!(prefix: "proc")

    attrs = %{
      run_id: run_id,
      os_process_id: os_process_id,
      line: ~s({"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}})
    }

    changeset = RunEvent.changeset(%RunEvent{}, attrs)
    assert changeset.valid?

    assert get_change(changeset, :run_id) == run_id
    assert get_change(changeset, :os_process_id) == os_process_id
    assert get_change(changeset, :line) =~ "hello"
  end

  test "changeset/2 validates required fields" do
    changeset = RunEvent.changeset(%RunEvent{}, %{})
    refute changeset.valid?

    errors = errors_on(changeset)
    assert "can't be blank" in errors.run_id
    assert "can't be blank" in errors.line
    refute Map.has_key?(errors, :seq)
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
      |> RunEvent.changeset(%{run_id: run.id, line: "some raw line"})
      |> Repo.insert()

    assert is_binary(event.id) and byte_size(event.id) > 0
    assert event.run_id == run.id
    # The database hands back the position it assigned.
    assert is_integer(event.seq)
    assert event.line == "some raw line"
  end
end
