defmodule Rail.Runs.Schemas.OsProcessTest do
  use Rail.DataCase, async: true

  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run

  test "changeset/2 with valid attributes" do
    run_id = UXID.generate!(prefix: "run")
    task_id = UXID.generate!(prefix: "tsk")
    now = DateTime.utc_now()

    attrs = %{
      run_id: run_id,
      task_id: task_id,
      kind: :stage,
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
    assert get_change(changeset, :kind) == :stage
    assert get_change(changeset, :os_pid) == 12_345
    assert get_change(changeset, :status) == :running
  end

  test "changeset/2 validates required fields" do
    changeset = OsProcess.changeset(%OsProcess{}, %{})
    refute changeset.valid?

    errors = errors_on(changeset)
    assert "can't be blank" in errors.run_id
    assert "can't be blank" in errors.task_id
    assert "can't be blank" in errors.kind
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
        kind: "invalid_kind",
        stream_path: "/tmp/rail/streams/test.ndjson",
        node: "node@host",
        status: "invalid_status",
        started_at: DateTime.utc_now()
      })

    refute changeset.valid?
    errors = errors_on(changeset)
    assert "is invalid" in errors.kind
    assert "is invalid" in errors.status
  end

  test "kinds/0 and statuses/0 return expected lists" do
    assert :stage in OsProcess.kinds()
    assert :chat in OsProcess.kinds()
    assert :rebase in OsProcess.kinds()

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
        kind: :stage,
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
