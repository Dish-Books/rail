defmodule Rail.Pipeline.Actions.UpdateRunTest do
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

  test "applies the changeset", %{run: run} do
    assert {:ok, %{status: :running}} = Pipeline.update_run(run, %{status: :running})
  end
end
