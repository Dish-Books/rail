defmodule Rail.Pipeline.Actions.CreateRunTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline

  test "inserts a run with a prefixed id" do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :starting,
        started_at: DateTime.utc_now()
      })

    assert run.id =~ "run_"
    assert run.status == :starting
  end
end
