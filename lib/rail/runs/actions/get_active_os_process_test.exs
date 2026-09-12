defmodule Rail.Runs.Actions.GetActiveOsProcessTest do
  use Rail.DataCase, async: true

  alias Rail.Runs
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run

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

  test "finds the live os process carrying a run", %{run: run} do
    %OsProcess{id: id} =
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

    assert %OsProcess{id: ^id} = Runs.get_active_os_process(run)

    assert %OsProcess{id: ^id} = Runs.get_active_os_process(run)
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

    %OsProcess{id: newest_id} =
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

    assert %OsProcess{id: ^newest_id} = Runs.get_active_os_process(run)
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

    assert Runs.get_active_os_process(run) == nil
    assert Runs.get_active_os_process(%Run{id: "run_nonexistent"}) == nil
  end
end
