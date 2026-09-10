defmodule Rail.Runs.Schemas.RunTest do
  use Rail.DataCase, async: true

  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run

  test "factory/0 returns a valid struct" do
    run = Run.factory()

    assert is_binary(run.role_run_id) and byte_size(run.role_run_id) > 0
    assert is_binary(run.task_id) and byte_size(run.task_id) > 0
    assert run.kind == :stage
    assert run.status == :starting
    assert is_binary(run.stream_path) and byte_size(run.stream_path) > 0
    assert is_binary(run.node) and byte_size(run.node) > 0
    assert is_binary(run.boot_id) and byte_size(run.boot_id) > 0
    assert %DateTime{} = run.started_at
  end

  test "changeset/2 with valid attributes" do
    role_run_id = UXID.generate!(prefix: "rr")
    task_id = UXID.generate!(prefix: "tsk")
    now = DateTime.utc_now()

    attrs = %{
      role_run_id: role_run_id,
      task_id: task_id,
      kind: :stage,
      os_pid: 12_345,
      stream_path: "/tmp/axis/streams/test.ndjson",
      node: "nonode@nohost",
      boot_id: "boot-1",
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
    assert "can't be blank" in errors.boot_id
    assert "can't be blank" in errors.status
    assert "can't be blank" in errors.started_at
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
        stream_path: "/tmp/axis/streams/#{role_run.id}.ndjson",
        node: "node@host",
        boot_id: "boot-test",
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
