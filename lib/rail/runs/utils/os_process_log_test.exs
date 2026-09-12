defmodule Rail.Runs.Utils.OsProcessLogTest do
  use Rail.DataCase, async: true

  import Rail.Runs.Utils.OsProcessLog

  alias Rail.Runs
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.RunEvent

  setup do
    {:ok, run} =
      Runs.create_run(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })

    spawn_os_process = fn ->
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/os_process_log/#{UXID.generate!()}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()
    end

    write = fn os_process, text ->
      Repo.insert!(%RunEvent{
        run_id: run.id,
        os_process_id: os_process.id,
        line: ~s({"type":"assistant","message":{"content":[{"type":"text","text":"#{text}"}]}})
      })
    end

    %{run: run, spawn_os_process: spawn_os_process, write: write}
  end

  test "reads only the lines the process itself wrote", %{spawn_os_process: spawn_os_process, write: write} do
    first = spawn_os_process.()
    write.(first, "Which database?")

    second = spawn_os_process.()
    write.(second, "Postgres it is.")

    assert os_process_log(first) == "Which database?"
    assert os_process_log(second) == "Postgres it is."
  end

  test "leaves out what Rail and the human contributed between turns", %{
    run: run,
    spawn_os_process: spawn_os_process,
    write: write
  } do
    os_process = spawn_os_process.()
    write.(os_process, "Done.")
    Runs.append_run_event(run, "[human] take another look")

    assert os_process_log(os_process) == "Done."
  end
end
