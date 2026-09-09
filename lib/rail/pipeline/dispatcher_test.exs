defmodule Rail.Pipeline.DispatcherTest do
  use Rail.DataCase, async: false

  alias Rail.Pipeline
  alias Rail.Pipeline.Dispatcher
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  setup do
    {:ok, pid} =
      Dispatcher.start_link(
        name: nil,
        start_timer: false,
        subscribe: false,
        dispatch_disabled: false,
        debounce_ms: 10
      )

    on_exit(fn ->
      try do
        GenServer.stop(pid)
      catch
        :exit, _err -> :ok
      end
    end)

    %{dispatcher: pid}
  end

  test "detects dispatch_disabled and toggles via set_dispatch_disabled", %{dispatcher: pid} do
    refute Dispatcher.dispatch_disabled?(pid)

    assert :ok = Dispatcher.set_dispatch_disabled(pid, true)
    assert Dispatcher.dispatch_disabled?(pid)

    assert :ok = Dispatcher.set_dispatch_disabled(pid, false)
    refute Dispatcher.dispatch_disabled?(pid)
  end

  test "initializes with dispatch_disabled true when AXIS_NO_DISPATCH=1 is set" do
    System.put_env("AXIS_NO_DISPATCH", "1")

    {:ok, pid} =
      Dispatcher.start_link(
        name: nil,
        start_timer: false,
        subscribe: false
      )

    assert Dispatcher.dispatch_disabled?(pid)

    System.delete_env("AXIS_NO_DISPATCH")
    GenServer.stop(pid)
  end

  test "pump returns {:disabled, []} when dispatch is disabled", %{dispatcher: pid} do
    Dispatcher.set_dispatch_disabled(pid, true)

    project = create_test_project()
    _role = create_test_role(%{project_id: project.id, stage: :product})
    _task = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})

    assert {:disabled, []} = Dispatcher.pump(pid)
  end

  test "pump evaluates queues and dispatches tasks to running state", %{dispatcher: pid} do
    project = create_test_project()
    _role = create_test_role(%{project_id: project.id, stage: :product, max_concurrent: 1})
    %Task{id: task_id} = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})

    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    assert {:ok, [%Task{id: ^task_id}]} = Dispatcher.pump(pid)

    # Verify task updated in database
    updated_task = Repo.get!(Task, task_id)
    assert updated_task.stage_state == :running

    # Verify dispatched broadcast
    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :dispatched}}
  end

  test "pump ignores roles without a stage", %{dispatcher: pid} do
    project = create_test_project()
    _role = create_test_role(%{project_id: project.id, stage: nil})
    _task = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})

    assert {:ok, []} = Dispatcher.pump(pid)
  end

  test "pump handles custom dispatch hook", _tags do
    caller = self()

    custom_hook = fn task, role ->
      send(caller, {:custom_dispatched, task.id, role.id})
      {:ok, task}
    end

    {:ok, pid} =
      Dispatcher.start_link(
        name: nil,
        start_timer: false,
        subscribe: false,
        dispatch_disabled: false,
        dispatch_hook: custom_hook
      )

    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :product, max_concurrent: 1})
    %Task{id: task_id} = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})

    assert {:ok, [%Task{id: ^task_id}]} = Dispatcher.pump(pid)

    assert_receive {:custom_dispatched, ^task_id, r_id}
    assert r_id == role.id

    GenServer.stop(pid)
  end

  test "handle_cast :pump performs queue pump in background", %{dispatcher: pid} do
    project = create_test_project()
    _role = create_test_role(%{project_id: project.id, stage: :product, max_concurrent: 1})
    task = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})

    GenServer.cast(pid, :pump)

    # Allow cast to process
    Process.sleep(30)

    updated_task = Repo.get!(Task, task.id)
    assert updated_task.stage_state == :running
  end

  test "debounces pipeline_changed event before pumping", %{dispatcher: pid} do
    project = create_test_project()
    _role = create_test_role(%{project_id: project.id, stage: :product, max_concurrent: 1})
    task = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})

    send(pid, {:pipeline_changed, %{task_id: task.id}})

    # Immediately, debounce timer is active and pump hasn't run yet
    assert Repo.get!(Task, task.id).stage_state == :queued

    # Send another pipeline_changed to test timer reset
    send(pid, {:pipeline_changed, %{task_id: task.id}})

    # Wait for debounce to fire
    Process.sleep(35)

    assert Repo.get!(Task, task.id).stage_state == :running
  end

  test "handles periodic tick and reschedules timer" do
    {:ok, pid} =
      Dispatcher.start_link(
        name: nil,
        start_timer: false,
        subscribe: false,
        dispatch_disabled: false,
        tick_interval_ms: 15
      )

    project = create_test_project()
    _role = create_test_role(%{project_id: project.id, stage: :product, max_concurrent: 1})
    task = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})

    send(pid, :tick)
    Process.sleep(25)

    assert Repo.get!(Task, task.id).stage_state == :running

    GenServer.stop(pid)
  end

  test "dispatch_now returns error when disabled", %{dispatcher: pid} do
    Dispatcher.set_dispatch_disabled(pid, true)
    task = create_test_task(%{stage: :product, stage_state: :queued})

    assert {:error, :dispatch_disabled} = Dispatcher.dispatch_now(pid, task)
  end

  test "dispatch_now returns error when task not found", %{dispatcher: pid} do
    assert {:error, :not_found} = Dispatcher.dispatch_now(pid, "tsk_000000000000000000000000")
  end

  test "dispatch_now returns error when task is not queued", %{dispatcher: pid} do
    task = create_test_task(%{stage: :product, stage_state: :running})

    assert {:error, {:not_queued, :running}} = Dispatcher.dispatch_now(pid, task)
  end

  test "dispatch_now returns error when no role is configured for stage", %{dispatcher: pid} do
    project = create_test_project()
    task = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})

    assert {:error, {:no_role_for_stage, :product}} = Dispatcher.dispatch_now(pid, task)
  end

  test "dispatch_now returns error when no concurrency slots are available", %{dispatcher: pid} do
    project = create_test_project()
    _role = create_test_role(%{project_id: project.id, stage: :product, max_concurrent: 1})

    _running = create_test_task(%{project_id: project.id, stage: :product, stage_state: :running})
    task = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})

    assert {:error, :no_available_slots} = Dispatcher.dispatch_now(pid, task)
  end

  test "dispatch_now successfully dispatches an eligible task by struct or id", %{dispatcher: pid} do
    project = create_test_project()
    _role = create_test_role(%{project_id: project.id, stage: :product, max_concurrent: 2})

    %Task{id: id1} = t1 = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})
    %Task{id: id2} = t2 = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})

    assert {:ok, %Task{id: ^id1, stage_state: :running}} = Dispatcher.dispatch_now(pid, t1)
    assert {:ok, %Task{id: ^id2, stage_state: :running}} = Dispatcher.dispatch_now(pid, t2.id)
  end

  test "dispatch_now resolves engineer role for rebasing task", %{dispatcher: pid} do
    project = create_test_project()
    _engineer_role = create_test_role(%{project_id: project.id, stage: :engineer, max_concurrent: 1})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :queued,
        is_rebasing: true
      })

    assert {:ok, %Task{id: ^task_id, stage_state: :running}} = Dispatcher.dispatch_now(pid, task)
  end

  test "cancels active debounce timer on terminate" do
    {:ok, pid} =
      Dispatcher.start_link(
        name: nil,
        start_timer: false,
        subscribe: false,
        dispatch_disabled: false,
        debounce_ms: 10_000
      )

    send(pid, {:pipeline_changed, %{}})
    Process.sleep(5)
    assert :ok = GenServer.stop(pid)
  end

  test "pump filters out tasks when dispatch hook returns non-ok" do
    failed_hook = fn _task, _role -> {:error, :failed} end

    {:ok, pid} =
      Dispatcher.start_link(
        name: nil,
        start_timer: false,
        subscribe: false,
        dispatch_disabled: false,
        dispatch_hook: failed_hook
      )

    project = create_test_project()
    _role = create_test_role(%{project_id: project.id, stage: :product, max_concurrent: 1})
    _task = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})

    assert {:ok, []} = Dispatcher.pump(pid)
    GenServer.stop(pid)
  end

  test "dispatch_now returns not_found for invalid task identifier", %{dispatcher: pid} do
    assert {:error, :not_found} = Dispatcher.dispatch_now(pid, 12_345)
    assert {:error, :not_found} = Dispatcher.dispatch_now(pid, :invalid_ref)
  end

  test "global Dispatcher process in supervision tree is alive" do
    assert is_pid(Process.whereis(Dispatcher))
    assert Pipeline.dispatch_disabled?() == true
  end
end
