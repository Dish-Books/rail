defmodule Rail.Runs.Actions.RunningTest do
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

  test "is true only while an os process is starting or running", %{run: run} do
    refute Runs.running?(run.task_id)

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/running.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    assert Runs.running?(run.task_id)

    os_process |> OsProcess.changeset(%{status: :finished}) |> Repo.update!()
    refute Runs.running?(run.task_id)
  end

  test "is false for anything that is not a task id" do
    refute Runs.running?("tsk_nonexistent")
    refute Runs.running?(123)
    refute Runs.running?(nil)
  end
end
