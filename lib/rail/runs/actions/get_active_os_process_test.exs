defmodule Rail.Runs.Actions.GetActiveOsProcessTest do
  use Rail.DataCase, async: true

  alias Rail.Runs
  alias Rail.Runs.Schemas.OsProcess

  setup do
    {:ok, run} =
      Runs.create_run(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })

    %{run: run}
  end

  test "finds a live os process by run id and by task id", %{run: run} do
    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/get_active_os_process.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    assert %OsProcess{id: id} = Runs.get_active_os_process(run.id)
    assert id == os_process.id

    assert %OsProcess{id: ^id} = Runs.get_active_os_process(run.task_id)
  end

  test "returns the most recent live process, ignoring finished ones", %{run: run} do
    %OsProcess{}
    |> OsProcess.changeset(%{
      run_id: run.id,
      task_id: run.task_id,
      stream_path: "/tmp/get_active_os_process.ndjson",
      node: to_string(Node.self()),
      status: :running,
      started_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    newest =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/get_active_os_process.ndjson",
        node: to_string(Node.self()),
        status: :starting,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    assert %OsProcess{id: id} = Runs.get_active_os_process(run.task_id)
    assert id == newest.id
  end

  test "returns nil when nothing is live", %{run: run} do
    %OsProcess{}
    |> OsProcess.changeset(%{
      run_id: run.id,
      task_id: run.task_id,
      stream_path: "/tmp/get_active_os_process.ndjson",
      node: to_string(Node.self()),
      status: :finished,
      started_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert Runs.get_active_os_process(run.task_id) == nil
    assert Runs.get_active_os_process("tsk_nonexistent") == nil
  end
end
