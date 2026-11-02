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

  test "a changed status or error is said on the pipeline topic, for lists that show the run", %{
    run: %{task_id: task_id} = run
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")

    {:ok, waiting} = Pipeline.update_run(run, %{status: :waiting_for_usage})
    assert_received {:pipeline_changed, ^task_id}

    {:ok, _failed} = Pipeline.update_run(waiting, %{error: "Failed to spawn runner"})
    assert_received {:pipeline_changed, ^task_id}
  end

  test "a write that changes neither says nothing", %{run: %{task_id: task_id} = run} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")

    {:ok, same} = Pipeline.update_run(run, %{status: :starting, conversation_id: "sess_quiet"})

    assert %{conversation_id: "sess_quiet"} = same
    refute_received {:pipeline_changed, ^task_id}
  end

  test "a refused write says nothing", %{run: %{task_id: task_id} = run} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
    {:ok, resumed} = Pipeline.update_run(run, %{conversation_id: "sess_one"})

    assert {:error, %Ecto.Changeset{}} = Pipeline.update_run(resumed, %{status: :running, conversation_id: "sess_two"})
    refute_received {:pipeline_changed, ^task_id}
  end
end
