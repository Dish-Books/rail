defmodule Rail.Runs.Schemas.RunTest do
  use Rail.DataCase, async: true

  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run

  test "changeset/2 with valid attributes" do
    role_run_id = UXID.generate!(prefix: "rr")
    task_id = UXID.generate!(prefix: "tsk")
    now = DateTime.utc_now()

    attrs = %{
      role_run_id: role_run_id,
      task_id: task_id,
      kind: :stage,
      os_pid: 12_345,
      stream_path: "/tmp/rail/streams/test.ndjson",
      node: "nonode@nohost",
      status: :running,
      started_at: now
    }

    changeset = Run.changeset(%Run{}, attrs)
    assert changeset.valid?

    assert get_change(changeset, :role_run_id) == role_run_id
    assert get_change(changeset, :task_id) == task_id
    assert get_change(changeset, :kind) == :stage
    assert get_change(changeset, :os_pid) == 12_345
    assert get_change(changeset, :status) == :running
  end

  test "changeset/2 validates required fields" do
    changeset = Run.changeset(%Run{}, %{})
    refute changeset.valid?

    errors = errors_on(changeset)
    assert "can't be blank" in errors.role_run_id
    assert "can't be blank" in errors.task_id
    assert "can't be blank" in errors.kind
    assert "can't be blank" in errors.stream_path
    assert "can't be blank" in errors.node
    assert "can't be blank" in errors.status
    assert "can't be blank" in errors.started_at
  end

  test "changeset/2 validates enum fields" do
    changeset =
      Run.changeset(%Run{}, %{
        role_run_id: UXID.generate!(prefix: "rr"),
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
    assert :stage in Run.kinds()
    assert :chat in Run.kinds()
    assert :rebase in Run.kinds()

    assert :starting in Run.statuses()
    assert :running in Run.statuses()
    assert :finished in Run.statuses()
    assert :adopted_dead in Run.statuses()
    assert :blocked_on_input in Run.statuses()
  end

  test "insert and retrieve run" do
    role_run =
      %RoleRun{}
      |> RoleRun.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, run} =
      %Run{}
      |> Run.changeset(%{
        role_run_id: role_run.id,
        task_id: role_run.task_id,
        kind: :stage,
        os_pid: 12_345,
        stream_path: "/tmp/rail/streams/#{role_run.id}.ndjson",
        node: "node@host",
        status: :starting,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    assert String.starts_with?(run.id, "run_")
    assert run.role_run_id == role_run.id
    assert run.os_pid == 12_345
    assert run.status == :starting
  end
end
