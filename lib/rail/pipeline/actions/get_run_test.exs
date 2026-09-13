defmodule Rail.Pipeline.Actions.GetRunTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline

  setup do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :starting,
        started_at: DateTime.utc_now()
      })

    %{run: run}
  end

  test "fetches a run by id", %{run: %{id: run_id}} do
    assert {:ok, %{id: ^run_id}} = Pipeline.get_run(run_id)
  end

  test "reports a missing run" do
    assert {:error, :not_found} = Pipeline.get_run("run_nonexistent")
  end
end
