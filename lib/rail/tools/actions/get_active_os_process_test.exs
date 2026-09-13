defmodule Rail.Tools.Actions.GetActiveOsProcessTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup do
    {:ok, run} =
      Pipeline.create_run(%{
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

    assert {:ok, %OsProcess{id: ^id}} = Tools.get_active_os_process(run)

    assert {:ok, %OsProcess{id: ^id}} = Tools.get_active_os_process(run)
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

    assert {:ok, %OsProcess{id: ^newest_id}} = Tools.get_active_os_process(run)
  end

  test "says so when nothing is live", %{run: run} do
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

    assert {:error, :os_process_not_active} = Tools.get_active_os_process(run)
    assert {:error, :os_process_not_active} = Tools.get_active_os_process(%Run{id: "run_nonexistent"})
  end
end
