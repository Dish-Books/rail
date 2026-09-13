defmodule Rail.Runs.Actions.GetRunTest do
  use Rail.DataCase, async: true

  alias Rail.Runs

  setup do
    {:ok, run} =
      Runs.create_run(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :starting,
        started_at: DateTime.utc_now()
      })

    %{run: run}
  end

  test "fetches a run by id", %{run: %{id: run_id}} do
    assert {:ok, %{id: ^run_id}} = Runs.get_run(run_id)
  end

  test "reports a missing run" do
    assert {:error, :not_found} = Runs.get_run("run_nonexistent")
  end
end
