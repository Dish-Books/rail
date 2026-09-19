defmodule Rail.Tools.Actions.GetOsProcessTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
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

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/get_os_process.ndjson",
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    %{os_process: os_process}
  end

  test "fetches an os process by id", %{os_process: %{id: os_process_id}} do
    assert {:ok, %OsProcess{id: ^os_process_id}} = Tools.get_os_process(os_process_id)
  end

  test "reports a missing os process" do
    assert {:error, :not_found} = Tools.get_os_process("osp_nonexistent")
  end
end
