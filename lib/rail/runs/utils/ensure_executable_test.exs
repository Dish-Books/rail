defmodule Rail.Runs.Utils.EnsureExecutableTest do
  use Rail.DataCase, async: true

  import Rail.Runs.Utils.EnsureExecutable

  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run

  setup do
    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :starting,
        started_at: DateTime.utc_now()
      })

    run =
      %Run{}
      |> Run.changeset(%{
        role_run_id: role_run.id,
        task_id: role_run.task_id,
        kind: :stage,
        stream_path: "/tmp/ensure_executable/#{role_run.id}.ndjson",
        node: to_string(Node.self()),
        status: :starting,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    %{role_run: role_run, run: run}
  end

  test "returns :ok for a real file", %{role_run: role_run, run: run} do
    assert :ok = ensure_executable("/bin/sh", run, role_run)
  end

  test "treats a directory as missing", %{role_run: role_run, run: run} do
    assert {:error, {:missing_binary, "/tmp", _run}} = ensure_executable("/tmp", run, role_run)
  end

  test "settles the run and role run when the binary is missing", %{
    role_run: role_run,
    run: run
  } do
    missing = "/path/to/nonexistent/cli_binary_xyz"

    assert {:error, {:missing_binary, ^missing, %Run{status: :finished}}} =
             ensure_executable(missing, run, role_run)

    assert %Run{status: :finished} = Repo.get!(Run, run.id)

    assert %RoleRun{status: :finished, exit_code: -1, error: error} =
             Repo.get!(RoleRun, role_run.id)

    assert error =~ "No such CLI binary"
  end
end
