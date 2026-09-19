defmodule Rail.Tools.Utils.EnsureExecutableTest do
  use Rail.DataCase, async: true

  import Rail.Tools.Utils.EnsureExecutable

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Tools.Schemas.OsProcess

  setup do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :starting,
        started_at: DateTime.utc_now()
      })

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/ensure_executable/#{run.id}.ndjson",
        status: :starting,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    %{run: run, os_process: os_process}
  end

  test "returns :ok for a real file", %{run: run, os_process: os_process} do
    assert :ok = ensure_executable("/bin/sh", os_process, run)
  end

  test "treats a directory as missing", %{run: run, os_process: os_process} do
    assert {:error, {:missing_binary, "/tmp", _run}} = ensure_executable("/tmp", os_process, run)
  end

  test "settles the run and its os process when the binary is missing", %{
    run: run,
    os_process: os_process
  } do
    missing = "/path/to/nonexistent/cli_binary_xyz"

    assert {:error, {:missing_binary, ^missing, %OsProcess{status: :finished}}} =
             ensure_executable(missing, os_process, run)

    assert %OsProcess{status: :finished} = Repo.get!(OsProcess, os_process.id)

    assert %Run{status: :finished, exit_code: -1, error: error} =
             Repo.get!(Run, run.id)

    assert error =~ "No such CLI binary"
  end
end
