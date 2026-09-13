defmodule Rail.Tools.Schemas.OsProcessTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Tools.Schemas.OsProcess

  test "changeset/2 with valid attributes" do
    run_id = UXID.generate!(prefix: "run")
    task_id = UXID.generate!(prefix: "tsk")
    now = DateTime.utc_now()

    attrs = %{
      run_id: run_id,
      task_id: task_id,
      os_pid: 12_345,
      stream_path: "/tmp/rail/streams/test.ndjson",
      node: "nonode@nohost",
      status: :running,
      started_at: now
    }

    changeset = OsProcess.changeset(%OsProcess{}, attrs)
    assert changeset.valid?

    assert get_change(changeset, :run_id) == run_id
    assert get_change(changeset, :task_id) == task_id
    refute get_field(changeset, :is_chat)
    assert get_change(changeset, :os_pid) == 12_345
    assert get_change(changeset, :status) == :running
  end

  test "changeset/2 validates required fields" do
    changeset = OsProcess.changeset(%OsProcess{}, %{})
    refute changeset.valid?

    errors = errors_on(changeset)
    assert "can't be blank" in errors.run_id
    assert "can't be blank" in errors.task_id
    assert "can't be blank" in errors.stream_path
    assert "can't be blank" in errors.node
    assert "can't be blank" in errors.status
    assert "can't be blank" in errors.started_at
  end

  test "changeset/2 validates enum fields" do
    changeset =
      OsProcess.changeset(%OsProcess{}, %{
        run_id: UXID.generate!(prefix: "run"),
        task_id: UXID.generate!(prefix: "tsk"),
        stream_path: "/tmp/rail/streams/test.ndjson",
        node: "node@host",
        status: "invalid_status",
        started_at: DateTime.utc_now()
      })

    refute changeset.valid?
    errors = errors_on(changeset)
    assert "is invalid" in errors.status
  end

  test "statuses/0 returns the expected list" do
    assert :starting in OsProcess.statuses()
    assert :running in OsProcess.statuses()
    assert :finished in OsProcess.statuses()
    assert :adopted_dead in OsProcess.statuses()
    assert :blocked_on_input in OsProcess.statuses()
  end

  test "insert and retrieve run" do
    run =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, os_process} =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        os_pid: 12_345,
        stream_path: "/tmp/rail/streams/#{run.id}.ndjson",
        node: "node@host",
        status: :starting,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    assert String.starts_with?(os_process.id, "proc_")
    assert os_process.run_id == run.id
    assert os_process.os_pid == 12_345
    assert os_process.status == :starting
  end
end
