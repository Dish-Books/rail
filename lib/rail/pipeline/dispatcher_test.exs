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
        debounce_ms: 10,
        dispatch_hook: &mock_dispatch_hook/2
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

  test "initializes with dispatch_disabled true when RAIL_NO_DISPATCH=1 is set" do
    System.put_env("RAIL_NO_DISPATCH", "1")

    {:ok, pid} =
      Dispatcher.start_link(
        name: nil,
        start_timer: false,
        subscribe: false
      )

    assert Dispatcher.dispatch_disabled?(pid)

    System.delete_env("RAIL_NO_DISPATCH")
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
        tick_interval_ms: 15,
        dispatch_hook: &mock_dispatch_hook/2
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

  test "default_dispatch_hook launches supervised stage run" do
    {:ok, pid} =
      Dispatcher.start_link(
        name: nil,
        start_timer: false,
        subscribe: false,
        dispatch_disabled: false
      )

    repo_dir = create_temp_git_repo()
    project = create_test_project(%{clone_path: repo_dir, default_branch: "main"})
    _role = create_test_role(%{project_id: project.id, stage: :product})
    %Task{id: task_id} = task = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})

    assert {:ok, %Task{id: ^task_id}} = Dispatcher.dispatch_now(pid, task)
    GenServer.stop(pid)
  end

  test "arms retry timer on pipeline_changed event with task_id", %{dispatcher: pid} do
    project = create_test_project()
    future = DateTime.shift(DateTime.utc_now(), second: 10)

    %Task{id: task_id} =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        retry_after: future
      })

    send(pid, {:pipeline_changed, %{task_id: task_id}})
    Process.sleep(20)

    timers = Dispatcher.retry_timers(pid)
    assert Map.has_key?(timers, task_id)
    assert is_reference(Map.get(timers, task_id))
  end

  test "arm_retry_timer client API arms timer, handles already armed, and non-waiting tasks", %{dispatcher: pid} do
    project = create_test_project()
    future = DateTime.shift(DateTime.utc_now(), second: 30)

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        retry_after: future
      })

    assert {:ok, ref} = Dispatcher.arm_retry_timer(pid, task)
    assert is_reference(ref)

    # Calling again returns already_armed
    assert {:ok, :already_armed} = Dispatcher.arm_retry_timer(pid, task_id)

    # Calling on task not waiting to retry
    not_waiting = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})
    assert {:error, :not_waiting_to_retry} = Dispatcher.arm_retry_timer(pid, not_waiting.id)
  end

  test "cancel_retry_timer cancels active timer and removes from state", %{dispatcher: pid} do
    project = create_test_project()
    future = DateTime.shift(DateTime.utc_now(), minute: 1)

    %Task{id: task_id} =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        retry_after: future
      })

    assert {:ok, _ref} = Dispatcher.arm_retry_timer(pid, task_id)
    assert Map.has_key?(Dispatcher.retry_timers(pid), task_id)

    assert :ok = Dispatcher.cancel_retry_timer(pid, task_id)
    refute Map.has_key?(Dispatcher.retry_timers(pid), task_id)

    # Idempotent cancel on missing timer
    assert :ok = Dispatcher.cancel_retry_timer(pid, task_id)
  end

  test "retry_stage cancels pending retry timer in dispatcher", %{dispatcher: pid} do
    project = create_test_project()
    _role = create_test_role(%{project_id: project.id, stage: :product})
    future = DateTime.shift(DateTime.utc_now(), minute: 1)

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        retry_after: future,
        error: "Transient timeout"
      })

    assert {:ok, _ref} = Dispatcher.arm_retry_timer(pid, task.id)
    assert Map.has_key?(Dispatcher.retry_timers(pid), task_id)

    assert {:ok, %Task{id: ^task_id, retry_after: nil}} =
             Pipeline.retry_stage(task, dispatcher: pid)

    refute Map.has_key?(Dispatcher.retry_timers(pid), task_id)
  end

  test "retry timer expiration clears retry_after and triggers pump when delay elapsed", %{dispatcher: pid} do
    project = create_test_project()
    _role = create_test_role(%{project_id: project.id, stage: :product, max_concurrent: 1})
    past = DateTime.shift(DateTime.utc_now(), second: -1)

    %Task{id: task_id} =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        retry_after: past
      })

    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    send(pid, {:retry_timer_expired, task_id})
    Process.sleep(30)

    updated_task = Repo.get!(Task, task_id)
    assert updated_task.retry_after == nil
    assert updated_task.stage_state == :running

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :retry_timer_expired}}
  end

  test "retry timer expiration re-arms timer if retry_after is still in future", %{dispatcher: pid} do
    project = create_test_project()
    future = DateTime.shift(DateTime.utc_now(), second: 30)

    %Task{id: task_id} =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        retry_after: future
      })

    send(pid, {:retry_timer_expired, task_id})
    Process.sleep(20)

    timers = Dispatcher.retry_timers(pid)
    assert Map.has_key?(timers, task_id)
    assert is_reference(Map.get(timers, task_id))

    updated_task = Repo.get!(Task, task_id)
    assert updated_task.retry_after
    assert updated_task.stage_state == :queued
  end

  test "boot re-arming on init re-arms future retries, clears elapsed retries, and pumps" do
    project = create_test_project()
    _role = create_test_role(%{project_id: project.id, stage: :product, max_concurrent: 2})

    future = DateTime.shift(DateTime.utc_now(), second: 20)
    past = DateTime.shift(DateTime.utc_now(), second: -20)

    %Task{id: future_task_id} =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        retry_after: future
      })

    %Task{id: past_task_id} =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        retry_after: past
      })

    {:ok, pid} =
      Dispatcher.start_link(
        name: nil,
        start_timer: false,
        subscribe: false,
        dispatch_disabled: false,
        rearm_on_boot: true,
        pump_on_boot: true,
        dispatch_hook: &mock_dispatch_hook/2
      )

    Process.sleep(40)

    # Future task timer is re-armed
    timers = Dispatcher.retry_timers(pid)
    assert Map.has_key?(timers, future_task_id)
    assert is_reference(Map.get(timers, future_task_id))

    # Past task has retry_after cleared and was dispatched by pump_on_boot
    past_task = Repo.get!(Task, past_task_id)
    assert past_task.retry_after == nil
    assert past_task.stage_state == :running

    GenServer.stop(pid)
  end

  test "manual rearm_pending_retries scans database and arms pending retries", %{dispatcher: pid} do
    project = create_test_project()
    future = DateTime.shift(DateTime.utc_now(), second: 15)

    %Task{id: task_id} =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        retry_after: future
      })

    assert Dispatcher.retry_timers(pid) == %{}

    assert :ok = Dispatcher.rearm_pending_retries(pid)
    assert Map.has_key?(Dispatcher.retry_timers(pid), task_id)
  end

  test "client functions handle unregistered atom dispatcher gracefully" do
    unregistered = :nonexistent_dispatcher_process_for_test

    assert Dispatcher.retry_timers(unregistered) == %{}
    assert :ok = Dispatcher.rearm_pending_retries(unregistered)
    assert :ok = Dispatcher.cancel_retry_timer(unregistered, "tsk_123")
    assert {:error, :dispatcher_not_running} = Dispatcher.arm_retry_timer(unregistered, "tsk_123")
    assert {:disabled, []} = Dispatcher.pump(unregistered)
    assert {:error, :not_found} = Dispatcher.dispatch_now(unregistered, "tsk_123", dispatch_disabled: false)
  end

  test "cancels active retry timers on terminate" do
    {:ok, pid} =
      Dispatcher.start_link(
        name: nil,
        start_timer: false,
        subscribe: false,
        dispatch_disabled: false
      )

    project = create_test_project()
    future = DateTime.shift(DateTime.utc_now(), minute: 1)

    %Task{id: task_id} =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        retry_after: future
      })

    assert {:ok, ref} = Dispatcher.arm_retry_timer(pid, task_id)
    assert Process.read_timer(ref) != false

    assert :ok = GenServer.stop(pid)
    assert Process.read_timer(ref) == false
  end

  test "exercises Dispatcher convenience helpers and 2-tuple dispatch_now", %{dispatcher: pid} do
    task = create_test_task(%{stage: :product, stage_state: :queued})

    assert {:error, :dispatch_disabled} = Dispatcher.dispatch_now(task)

    assert {:error, {:no_role_for_stage, :product}} =
             Dispatcher.dispatch_now(task, dispatch_disabled: false)

    assert {:error, :dispatcher_not_running} =
             Dispatcher.arm_retry_timer(:non_existent_dispatcher, task)

    assert {:error, :not_waiting_to_retry} = Dispatcher.arm_retry_timer(task)

    assert :ok = Dispatcher.cancel_retry_timer(:non_existent_dispatcher, task)
    assert Dispatcher.retry_timers(:non_existent_dispatcher) == %{}

    assert {:error, {:no_role_for_stage, :product}} =
             GenServer.call(pid, {:dispatch_now, task.id})

    assert :ok = Dispatcher.cancel_retry_timer(pid, 12_345)
    assert :ok = Dispatcher.cancel_retry_timer(task)

    send(pid, {:retry_timer_expired, "tsk_missing"})
    Process.sleep(10)

    future = DateTime.shift(DateTime.utc_now(), minute: 1)
    task_armed = create_test_task(%{stage: :product, stage_state: :queued, retry_after: future})
    assert {:ok, _ref} = Dispatcher.arm_retry_timer(pid, task_armed.id)
    send(pid, {:pipeline_changed, %{task_id: task_armed.id}})
    Process.sleep(10)
    assert Map.has_key?(Dispatcher.retry_timers(pid), task_armed.id)
  end
end
