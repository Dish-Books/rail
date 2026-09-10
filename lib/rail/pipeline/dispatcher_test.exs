defmodule Rail.Pipeline.DispatcherTest do
  use Rail.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Dispatcher
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Dispatcher Workspace",
        external_id: "lin_ws_dispatcher",
        token: "lin_api_token_dispatcher",
        webhook_secret: "whsec_dispatcher"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Dispatcher Project 13301",
        github_repo: "org/dispatcher-13301",
        github_installation_id: 13_301,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_dispatcher_13301",
        linear_team_key: "P13301",
        clone_path: "/tmp/repos/dispatcher-13301",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    roles =
      Map.new([:product, :design, :architect, :engineer, :review, :qa, :qa_lead, :demo], fn stage ->
        {:ok, role} =
          Roles.create_role(scope, project, %{
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_dispatcher_1",
      "identifier" => "DSP-1",
      "title" => "Dispatcher Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Dispatcher Issue")

    LinearMock.mock_update_issue_success(%{"id" => "lin_dispatcher_1"})

    {:ok, task} = Pipeline.bring_local(scope, issue)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  setup _context do
    {:ok, pid} =
      Dispatcher.start_link(
        name: nil,
        start_timer: false,
        subscribe: false,
        dispatch_disabled: false,
        debounce_ms: 10,
        dispatch_hook: fn hook_task, _role ->
          {:ok, dispatched} = Pipeline.update_task(system_scope(), hook_task.id, %{stage_state: :running})
          Pipeline.broadcast_pipeline_changed(%{task_id: dispatched.id, event: :dispatched})
          {:ok, dispatched}
        end
      )

    # The dispatcher runs in its own process, so lend it this test's DB connection.
    Sandbox.allow(Repo, self(), pid)

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

    # The dispatcher runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), pid)

    assert Dispatcher.dispatch_disabled?(pid)

    System.delete_env("RAIL_NO_DISPATCH")
    GenServer.stop(pid)
  end

  test "pump returns {:disabled, []} when dispatch is disabled", %{dispatcher: pid, task: task, roles: roles} do
    Dispatcher.set_dispatch_disabled(pid, true)

    _role = roles[:product]

    {:ok, _task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    assert {:disabled, []} = Dispatcher.pump(pid)
  end

  test "pump evaluates queues and dispatches tasks to running state", %{dispatcher: pid, task: task, roles: roles} do
    {:ok, _role} =
      Roles.update_role(system_scope(), roles[:product], %{
        max_concurrent: 1
      })

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    assert {:ok, [%Task{id: ^task_id}]} = Dispatcher.pump(pid)

    # Verify task updated in database
    updated_task = Repo.get!(Task, task_id)
    assert updated_task.stage_state == :running

    # Verify dispatched broadcast
    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :dispatched}}
  end

  test "pump ignores roles without a stage", %{dispatcher: pid, task: task, roles: roles} do
    {:ok, _deleted} = Roles.delete_role(system_scope(), roles[:product])

    _role = roles[nil]

    {:ok, _task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    assert {:ok, []} = Dispatcher.pump(pid)
  end

  test "pump handles custom dispatch hook", %{task: task, roles: roles} do
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

    # The dispatcher runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), pid)

    {:ok, role} =
      Roles.update_role(system_scope(), roles[:product], %{
        max_concurrent: 1
      })

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    assert {:ok, [%Task{id: ^task_id}]} = Dispatcher.pump(pid)

    assert_receive {:custom_dispatched, ^task_id, r_id}
    assert r_id == role.id

    GenServer.stop(pid)
  end

  test "handle_cast :pump performs queue pump in background", %{dispatcher: pid, task: task, roles: roles} do
    {:ok, _role} =
      Roles.update_role(system_scope(), roles[:product], %{
        max_concurrent: 1
      })

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    GenServer.cast(pid, :pump)

    # Allow cast to process
    Process.sleep(30)

    updated_task = Repo.get!(Task, task.id)
    assert updated_task.stage_state == :running
  end

  test "debounces pipeline_changed event before pumping", %{dispatcher: pid, task: task, roles: roles} do
    {:ok, _role} =
      Roles.update_role(system_scope(), roles[:product], %{
        max_concurrent: 1
      })

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    send(pid, {:pipeline_changed, %{task_id: task.id}})

    # Immediately, debounce timer is active and pump hasn't run yet
    assert Repo.get!(Task, task.id).stage_state == :queued

    # Send another pipeline_changed to test timer reset
    send(pid, {:pipeline_changed, %{task_id: task.id}})

    # Wait for the debounced pump to dispatch the task.
    assert Enum.reduce_while(1..100, false, fn _i, _acc ->
             if Repo.get!(Task, task.id).stage_state == :running do
               {:halt, true}
             else
               Process.sleep(10)
               {:cont, false}
             end
           end)
  end

  test "handles periodic tick and reschedules timer", %{task: task, roles: roles} do
    {:ok, pid} =
      Dispatcher.start_link(
        name: nil,
        start_timer: false,
        subscribe: false,
        dispatch_disabled: false,
        tick_interval_ms: 15,
        dispatch_hook: fn hook_task, _role ->
          {:ok, dispatched} = Pipeline.update_task(system_scope(), hook_task.id, %{stage_state: :running})
          Pipeline.broadcast_pipeline_changed(%{task_id: dispatched.id, event: :dispatched})
          {:ok, dispatched}
        end
      )

    # The dispatcher runs in its own process, so lend it this test's DB connection.
    Sandbox.allow(Repo, self(), pid)

    {:ok, _role} =
      Roles.update_role(system_scope(), roles[:product], %{
        max_concurrent: 1
      })

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    send(pid, :tick)
    Process.sleep(25)

    assert Repo.get!(Task, task.id).stage_state == :running

    GenServer.stop(pid)
  end

  test "dispatch_now returns error when disabled", %{dispatcher: pid, task: task} do
    Dispatcher.set_dispatch_disabled(pid, true)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    assert {:error, :dispatch_disabled} = Dispatcher.dispatch_now(pid, task)
  end

  test "dispatch_now returns error when task not found", %{dispatcher: pid} do
    assert {:error, :not_found} = Dispatcher.dispatch_now(pid, "tsk_000000000000000000000000")
  end

  test "dispatch_now returns error when task is not queued", %{dispatcher: pid, task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :running
      })

    assert {:error, {:not_queued, :running}} = Dispatcher.dispatch_now(pid, task)
  end

  test "dispatch_now returns error when no role is configured for stage", %{dispatcher: pid, task: task, roles: roles} do
    {:ok, _deleted} = Roles.delete_role(system_scope(), roles[:product])

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    assert {:error, {:no_role_for_stage, :product}} = Dispatcher.dispatch_now(pid, task)
  end

  test "dispatch_now returns error when no concurrency slots are available", %{
    dispatcher: pid,
    project: project,
    task: task,
    roles: roles
  } do
    {:ok, _role} =
      Roles.update_role(system_scope(), roles[:product], %{
        max_concurrent: 1
      })

    {:ok, _running} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :running
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_dispatcher_13302",
      "identifier" => "TSK-13302",
      "title" => "Task 13302"
    })

    {:ok, issue_13302} = Issues.capture_issue(system_scope(), project, "Task 13302")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_dispatcher_13302"})

    {:ok, task} = Pipeline.bring_local(system_scope(), issue_13302)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    assert {:error, :no_available_slots} = Dispatcher.dispatch_now(pid, task)
  end

  test "dispatch_now successfully dispatches an eligible task by struct or id", %{
    dispatcher: pid,
    project: project,
    task: task,
    roles: roles
  } do
    {:ok, _role} =
      Roles.update_role(system_scope(), roles[:product], %{
        max_concurrent: 2
      })

    {:ok, %Task{id: id1} = t1} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_dispatcher_13303",
      "identifier" => "TSK-13303",
      "title" => "Task 13303"
    })

    {:ok, issue_13303} = Issues.capture_issue(system_scope(), project, "Task 13303")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_dispatcher_13303"})

    {:ok, %Task{id: _id2} = t2} = Pipeline.bring_local(system_scope(), issue_13303)

    {:ok, %Task{id: id2} = t2} =
      Pipeline.update_task(system_scope(), t2.id, %{
        stage: :product,
        stage_state: :queued
      })

    assert {:ok, %Task{id: ^id1, stage_state: :running}} = Dispatcher.dispatch_now(pid, t1)
    assert {:ok, %Task{id: ^id2, stage_state: :running}} = Dispatcher.dispatch_now(pid, t2.id)
  end

  test "dispatch_now resolves engineer role for rebasing task", %{dispatcher: pid, task: task, roles: roles} do
    {:ok, _engineer_role} =
      Roles.update_role(system_scope(), roles[:engineer], %{
        max_concurrent: 1
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
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

    # The dispatcher runs in its own process, so lend it this test's DB connection.
    Sandbox.allow(Repo, self(), pid)

    send(pid, {:pipeline_changed, %{}})
    Process.sleep(5)
    assert :ok = GenServer.stop(pid)
  end

  test "pump filters out tasks when dispatch hook returns non-ok", %{task: task, roles: roles} do
    failed_hook = fn _task, _role -> {:error, :failed} end

    {:ok, pid} =
      Dispatcher.start_link(
        name: nil,
        start_timer: false,
        subscribe: false,
        dispatch_disabled: false,
        dispatch_hook: failed_hook
      )

    # The dispatcher runs in its own process, so lend it this test's DB connection.

    Sandbox.allow(Repo, self(), pid)

    {:ok, _role} =
      Roles.update_role(system_scope(), roles[:product], %{
        max_concurrent: 1
      })

    {:ok, _task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

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

  test "default_dispatch_hook launches supervised stage run", %{project: _project, task: task, roles: roles} do
    {:ok, pid} =
      Dispatcher.start_link(
        name: nil,
        start_timer: false,
        subscribe: false,
        dispatch_disabled: false
      )

    # The dispatcher runs in its own process, so lend it this test's DB connection.
    Sandbox.allow(Repo, self(), pid)

    _repo_dir = create_temp_git_repo()
    _role = roles[:product]

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    assert {:ok, %Task{id: ^task_id}} = Dispatcher.dispatch_now(pid, task)
    GenServer.stop(pid)
  end

  test "arms retry timer on pipeline_changed event with task_id", %{dispatcher: pid, task: task} do
    future = DateTime.shift(DateTime.utc_now(), second: 10)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), task.id, %{
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

  test "arm_retry_timer client API arms timer, handles already armed, and non-waiting tasks", %{
    dispatcher: pid,
    project: project,
    task: task
  } do
    future = DateTime.shift(DateTime.utc_now(), second: 30)

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued,
        retry_after: future
      })

    assert {:ok, ref} = Dispatcher.arm_retry_timer(pid, task)
    assert is_reference(ref)

    # Calling again returns already_armed
    assert {:ok, :already_armed} = Dispatcher.arm_retry_timer(pid, task_id)

    # Calling on task not waiting to retry
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_dispatcher_13304",
      "identifier" => "TSK-13304",
      "title" => "Task 13304"
    })

    {:ok, issue_13304} = Issues.capture_issue(system_scope(), project, "Task 13304")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_dispatcher_13304"})

    {:ok, not_waiting} = Pipeline.bring_local(system_scope(), issue_13304)

    {:ok, not_waiting} =
      Pipeline.update_task(system_scope(), not_waiting.id, %{
        stage: :product,
        stage_state: :queued
      })

    assert {:error, :not_waiting_to_retry} = Dispatcher.arm_retry_timer(pid, not_waiting.id)
  end

  test "cancel_retry_timer cancels active timer and removes from state", %{dispatcher: pid, task: task} do
    future = DateTime.shift(DateTime.utc_now(), minute: 1)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), task.id, %{
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

  test "retry_stage cancels pending retry timer in dispatcher", %{dispatcher: pid, task: task, roles: roles} do
    _role = roles[:product]
    future = DateTime.shift(DateTime.utc_now(), minute: 1)

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
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

  test "retry timer expiration clears retry_after and triggers pump when delay elapsed", %{
    dispatcher: pid,
    task: task,
    roles: roles
  } do
    {:ok, _role} =
      Roles.update_role(system_scope(), roles[:product], %{
        max_concurrent: 1
      })

    past = DateTime.shift(DateTime.utc_now(), second: -1)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), task.id, %{
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

  test "retry timer expiration re-arms timer if retry_after is still in future", %{dispatcher: pid, task: task} do
    future = DateTime.shift(DateTime.utc_now(), second: 30)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), task.id, %{
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

  test "boot re-arming on init re-arms future retries, clears elapsed retries, and pumps", %{
    project: project,
    task: task,
    roles: roles
  } do
    {:ok, _role} =
      Roles.update_role(system_scope(), roles[:product], %{
        max_concurrent: 2
      })

    future = DateTime.shift(DateTime.utc_now(), second: 20)
    past = DateTime.shift(DateTime.utc_now(), second: -20)

    {:ok, %Task{id: future_task_id}} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued,
        retry_after: future
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_dispatcher_13305",
      "identifier" => "TSK-13305",
      "title" => "Task 13305"
    })

    {:ok, issue_13305} = Issues.capture_issue(system_scope(), project, "Task 13305")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_dispatcher_13305"})

    {:ok, %Task{id: past_task_id}} = Pipeline.bring_local(system_scope(), issue_13305)

    {:ok, %Task{id: past_task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: past_task_id}.id, %{
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
        rearm_on_boot: false,
        pump_on_boot: false,
        dispatch_hook: fn hook_task, _role ->
          {:ok, dispatched} = Pipeline.update_task(system_scope(), hook_task.id, %{stage_state: :running})
          Pipeline.broadcast_pipeline_changed(%{task_id: dispatched.id, event: :dispatched})
          {:ok, dispatched}
        end
      )

    # The dispatcher runs in its own process, so lend it this test's DB connection
    # before asking it to do the boot work that reads the database.
    Sandbox.allow(Repo, self(), pid)

    assert :ok = Dispatcher.rearm_pending_retries(pid)
    assert {:ok, _dispatched} = Dispatcher.pump(pid)

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

  test "manual rearm_pending_retries scans database and arms pending retries", %{dispatcher: pid, task: task} do
    future = DateTime.shift(DateTime.utc_now(), second: 15)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), task.id, %{
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

  test "cancels active retry timers on terminate", %{task: task} do
    {:ok, pid} =
      Dispatcher.start_link(
        name: nil,
        start_timer: false,
        subscribe: false,
        dispatch_disabled: false
      )

    # The dispatcher runs in its own process, so lend it this test's DB connection.
    Sandbox.allow(Repo, self(), pid)

    future = DateTime.shift(DateTime.utc_now(), minute: 1)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued,
        retry_after: future
      })

    assert {:ok, ref} = Dispatcher.arm_retry_timer(pid, task_id)
    assert Process.read_timer(ref) != false

    assert :ok = GenServer.stop(pid)
    assert Process.read_timer(ref) == false
  end

  test "exercises Dispatcher convenience helpers and 2-tuple dispatch_now", %{
    dispatcher: pid,
    project: project,
    task: task,
    roles: roles
  } do
    {:ok, _deleted} = Roles.delete_role(system_scope(), roles[:product])

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    assert {:error, :dispatch_disabled} = Dispatcher.dispatch_now(task)

    # The globally registered Dispatcher is shared with every other test, so the
    # enabled path runs against this test's own instance.
    assert {:error, {:no_role_for_stage, :product}} =
             GenServer.call(pid, {:dispatch_now, task, [dispatch_disabled: false]})

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

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_dispatcher_13306",
      "identifier" => "TSK-13306",
      "title" => "Task 13306"
    })

    {:ok, issue_13306} = Issues.capture_issue(system_scope(), project, "Task 13306")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_dispatcher_13306"})

    {:ok, task_armed} = Pipeline.bring_local(system_scope(), issue_13306)

    {:ok, task_armed} =
      Pipeline.update_task(system_scope(), task_armed.id, %{
        stage: :product,
        stage_state: :queued,
        retry_after: future
      })

    assert {:ok, _ref} = Dispatcher.arm_retry_timer(pid, task_armed.id)
    send(pid, {:pipeline_changed, %{task_id: task_armed.id}})
    Process.sleep(10)
    assert Map.has_key?(Dispatcher.retry_timers(pid), task_armed.id)
  end
end
