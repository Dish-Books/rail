defmodule Rail.Runs.Actions.UpdateRunTest do
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

  test "applies the changeset", %{run: run} do
    assert {:ok, %{status: :running}} = Runs.update_run(run, %{status: :running})
  end
end
