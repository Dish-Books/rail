defmodule Rail.Pipeline.Dispatcher do
  @moduledoc """
  GenServer responsible for queue pumping, concurrency management, retry timers,
  and task dispatching.

  Subscribes to `"pipeline:changed"` PubSub events and runs periodic queue sweeps.
  When `RAIL_NO_DISPATCH=1` is set in the environment (or `:no_dispatch` in config),
  runs are not started, but the process maintains state and responds to pumps.
  """
  use GenServer

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Pipeline.Queue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  require Logger

  @default_tick_interval_ms 60_000
  @default_debounce_ms 100

  defstruct [
    :dispatch_disabled,
    :dispatch_hook,
    :tick_timer,
    :tick_interval_ms,
    :debounce_timer,
    :debounce_ms,
    retry_timers: %{}
  ]

  # --- Client API ---

  @doc """
  Starts the Dispatcher GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Triggers an immediate synchronous queue pump across all active projects and roles.
  """
  def pump(server \\ __MODULE__) do
    if is_atom(server) and is_nil(Process.whereis(server)) do
      {:disabled, []}
    else
      GenServer.call(server, :pump)
    end
  end

  @doc """
  Attempts to immediately dispatch a specific task if slots are available.
  """
  def dispatch_now(task_or_id) do
    dispatch_now(__MODULE__, task_or_id, [])
  end

  def dispatch_now(server, task_or_id) when is_pid(server) or is_atom(server) do
    dispatch_now(server, task_or_id, [])
  end

  def dispatch_now(task_or_id, opts) when is_list(opts) do
    dispatch_now(__MODULE__, task_or_id, opts)
  end

  def dispatch_now(server, task_or_id, opts) do
    if is_atom(server) and is_nil(Process.whereis(server)) do
      Rail.Pipeline.dispatch_now(Scope.for_system(), task_or_id, opts)
    else
      GenServer.call(server, {:dispatch_now, task_or_id, opts})
    end
  end

  @doc """
  Returns whether dispatch is currently disabled (via `RAIL_NO_DISPATCH=1` or config).
  """
  def dispatch_disabled?(server \\ __MODULE__) do
    GenServer.call(server, :dispatch_disabled?)
  end

  @doc """
  Manually enables or disables dispatch on this Dispatcher instance.
  """
  def set_dispatch_disabled(server \\ __MODULE__, disabled?) when is_boolean(disabled?) do
    GenServer.call(server, {:set_dispatch_disabled, disabled?})
  end

  @doc """
  Arms a retry timer for a task waiting in retry backoff.
  """
  def arm_retry_timer(task_or_id) do
    arm_retry_timer(__MODULE__, task_or_id)
  end

  def arm_retry_timer(server, task_or_id) when is_pid(server) or is_atom(server) do
    task_id = resolve_task_id(task_or_id)

    if is_atom(server) and is_nil(Process.whereis(server)) do
      {:error, :dispatcher_not_running}
    else
      GenServer.call(server, {:arm_retry_timer, task_id})
    end
  end

  @doc """
  Cancels any active retry timer for the given task.
  """
  def cancel_retry_timer(task_or_id) do
    cancel_retry_timer(__MODULE__, task_or_id)
  end

  def cancel_retry_timer(server, task_or_id) when is_pid(server) or is_atom(server) do
    task_id = resolve_task_id(task_or_id)

    if is_atom(server) and is_nil(Process.whereis(server)) do
      :ok
    else
      GenServer.call(server, {:cancel_retry_timer, task_id})
    end
  end

  @doc """
  Returns the map of currently active retry timers (`%{task_id => timer_ref}`).
  """
  def retry_timers(server \\ __MODULE__) do
    if is_atom(server) and is_nil(Process.whereis(server)) do
      %{}
    else
      GenServer.call(server, :retry_timers)
    end
  end

  @doc """
  Manually triggers re-arming of pending retries from the database.
  """
  def rearm_pending_retries(server \\ __MODULE__) do
    if is_atom(server) and is_nil(Process.whereis(server)) do
      :ok
    else
      GenServer.call(server, :rearm_pending_retries)
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe, true) do
      Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    end

    env_disabled = System.get_env("RAIL_NO_DISPATCH") == "1"
    config_disabled = Application.get_env(:rail, :no_dispatch, false)
    dispatch_disabled = Keyword.get(opts, :dispatch_disabled, env_disabled or config_disabled)

    if dispatch_disabled do
      Logger.info("RAIL_NO_DISPATCH=1 is set. Dispatching is disabled.")
    end

    tick_interval_ms = Keyword.get(opts, :tick_interval_ms, @default_tick_interval_ms)
    debounce_ms = Keyword.get(opts, :debounce_ms, @default_debounce_ms)
    dispatch_hook = Keyword.get(opts, :dispatch_hook, &default_dispatch_hook/2)

    start_timer? = Keyword.get(opts, :start_timer, true)
    tick_timer = if start_timer?, do: schedule_tick(tick_interval_ms)

    rearm_on_boot = Keyword.get(opts, :rearm_on_boot, start_timer? and not dispatch_disabled)
    pump_on_boot = Keyword.get(opts, :pump_on_boot, start_timer? and not dispatch_disabled)
    tables_ready? = tables_exist?()

    retry_timers =
      if rearm_on_boot and tables_ready? do
        do_rearm_pending_retries()
      else
        %{}
      end

    if pump_on_boot and tables_ready? do
      send(self(), :pump)
    end

    state = %__MODULE__{
      dispatch_disabled: dispatch_disabled,
      dispatch_hook: dispatch_hook,
      tick_timer: tick_timer,
      tick_interval_ms: tick_interval_ms,
      debounce_timer: nil,
      debounce_ms: debounce_ms,
      retry_timers: retry_timers
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:pump, {from_pid, _tag}, state) do
    allow_sandbox(from_pid)
    result = do_pump(state)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:dispatch_disabled?, _from, state) do
    {:reply, state.dispatch_disabled, state}
  end

  @impl true
  def handle_call({:set_dispatch_disabled, disabled?}, _from, state) do
    {:reply, :ok, %{state | dispatch_disabled: disabled?}}
  end

  @impl true
  def handle_call({:dispatch_now, task_or_id}, from, state) do
    handle_call({:dispatch_now, task_or_id, []}, from, state)
  end

  @impl true
  def handle_call({:dispatch_now, task_or_id, opts}, {from_pid, _tag}, state) do
    allow_sandbox(from_pid)

    opts =
      opts
      |> Keyword.put_new(:dispatch_disabled, state.dispatch_disabled)
      |> Keyword.put_new(:dispatch_hook, state.dispatch_hook)

    result = Rail.Pipeline.dispatch_now(Scope.for_system(), task_or_id, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:arm_retry_timer, task_id}, {from_pid, _tag}, state) do
    allow_sandbox(from_pid)
    {reply, new_state} = do_arm_retry_timer(task_id, state)
    {:reply, reply, new_state}
  end

  @impl true
  def handle_call({:cancel_retry_timer, task_id}, _from, state) do
    state =
      case Map.pop(state.retry_timers, task_id) do
        {timer_ref, new_timers} when is_reference(timer_ref) ->
          Process.cancel_timer(timer_ref)
          %{state | retry_timers: new_timers}

        {_nil, _timers} ->
          state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:retry_timers, _from, state) do
    {:reply, state.retry_timers, state}
  end

  @impl true
  def handle_call(:rearm_pending_retries, {from_pid, _tag}, state) do
    allow_sandbox(from_pid)
    new_timers = do_rearm_pending_retries()
    merged_timers = Map.merge(state.retry_timers || %{}, new_timers)
    {:reply, :ok, %{state | retry_timers: merged_timers}}
  end

  @impl true
  def handle_cast(:pump, state) do
    _result = do_pump(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:pipeline_changed, meta}, state) do
    state =
      if state.dispatch_disabled do
        state
      else
        case meta do
          %{task_id: task_id} when is_binary(task_id) ->
            maybe_arm_task_retry(task_id, state)

          _other ->
            state
        end
      end

    if state.debounce_timer do
      Process.cancel_timer(state.debounce_timer)
    end

    timer = Process.send_after(self(), :debounced_pump, state.debounce_ms)
    {:noreply, %{state | debounce_timer: timer}}
  end

  @impl true
  def handle_info(:debounced_pump, state) do
    _result = do_pump(state)
    {:noreply, %{state | debounce_timer: nil}}
  end

  @impl true
  def handle_info(:pump, state) do
    _result = do_pump(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    _result = do_pump(state)
    tick_timer = schedule_tick(state.tick_interval_ms)
    {:noreply, %{state | tick_timer: tick_timer}}
  end

  @impl true
  def handle_info({:retry_timer_expired, task_id}, state) do
    new_timers = Map.delete(state.retry_timers, task_id)
    state = %{state | retry_timers: new_timers}

    state =
      case Repo.get(Task, task_id) do
        %Task{stage_state: :queued, retry_after: %DateTime{} = retry_after} = task ->
          now = DateTime.utc_now()

          if DateTime.after?(retry_after, now) do
            remaining_ms = max(0, DateTime.diff(retry_after, now, :millisecond))
            ref = Process.send_after(self(), {:retry_timer_expired, task_id}, remaining_ms)
            %{state | retry_timers: Map.put(state.retry_timers, task_id, ref)}
          else
            {:ok, updated_task} =
              task
              |> Task.changeset(%{retry_after: nil})
              |> Repo.update()

            Rail.Pipeline.broadcast_pipeline_changed(%{
              task_id: updated_task.id,
              event: :retry_timer_expired
            })

            _result = do_pump(state)
            state
          end

        _other ->
          state
      end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.tick_timer do
      Process.cancel_timer(state.tick_timer)
    end

    if state.debounce_timer do
      Process.cancel_timer(state.debounce_timer)
    end

    if is_map(state.retry_timers) do
      Enum.each(state.retry_timers, fn {_task_id, timer_ref} ->
        if is_reference(timer_ref) do
          Process.cancel_timer(timer_ref)
        end
      end)
    end

    :ok
  end

  # --- Internal Helpers ---

  defp default_dispatch_hook(%Task{} = task, _role) do
    caller = self()

    case Elixir.Task.Supervisor.start_child(Rail.TaskSupervisor, fn ->
           allow_sandbox(caller)
           Rail.Pipeline.start_stage_run(task)
         end) do
      {:ok, _pid} ->
        {:ok, task}

      # coveralls-ignore-start
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp do_pump(%__MODULE__{dispatch_disabled: true}) do
    Logger.info("RAIL_NO_DISPATCH=1 is set. Dispatching is disabled.")
    {:disabled, []}
  end

  defp do_pump(%__MODULE__{dispatch_hook: dispatch_hook}) do
    scope = Scope.for_system()
    projects = Rail.Projects.list_projects(scope)

    dispatched_tasks =
      Enum.flat_map(projects, fn project ->
        roles = Rail.Roles.list_roles(scope, project.id)

        Enum.flat_map(roles, fn role ->
          if is_nil(role.stage) do
            []
          else
            dispatch_eligible_for_role(project, role, dispatch_hook)
          end
        end)
      end)

    {:ok, dispatched_tasks}
  end

  defp dispatch_eligible_for_role(project, role, dispatch_hook) do
    tasks = Queue.eligible_tasks(project, role)

    Enum.flat_map(tasks, fn task ->
      case dispatch_hook.(task, role) do
        {:ok, dispatched} -> [dispatched]
        _other -> []
      end
    end)
  end

  defp do_arm_retry_timer(task_id, state) do
    if Map.has_key?(state.retry_timers, task_id) do
      {{:ok, :already_armed}, state}
    else
      case Repo.get(Task, task_id) do
        %Task{stage_state: :queued, retry_after: %DateTime{} = retry_after} = task ->
          now = DateTime.utc_now()
          delay_ms = max(0, DateTime.diff(retry_after, now, :millisecond))
          ref = Process.send_after(self(), {:retry_timer_expired, task.id}, delay_ms)
          {{:ok, ref}, %{state | retry_timers: Map.put(state.retry_timers, task.id, ref)}}

        _other ->
          {{:error, :not_waiting_to_retry}, state}
      end
    end
  end

  defp maybe_arm_task_retry(task_id, state) do
    if Map.has_key?(state.retry_timers, task_id) do
      state
    else
      case Repo.get(Task, task_id) do
        %Task{stage_state: :queued, retry_after: %DateTime{} = retry_after} ->
          now = DateTime.utc_now()
          delay_ms = max(0, DateTime.diff(retry_after, now, :millisecond))
          ref = Process.send_after(self(), {:retry_timer_expired, task_id}, delay_ms)
          %{state | retry_timers: Map.put(state.retry_timers, task_id, ref)}

        _other ->
          state
      end
    end

    # coveralls-ignore-start
  rescue
    _error ->
      state
      # coveralls-ignore-stop
  end

  defp do_rearm_pending_retries do
    now = DateTime.utc_now()

    query =
      from t in Task,
        where: t.stage_state == :queued and not is_nil(t.retry_after)

    tasks = Repo.all(query)

    Enum.reduce(tasks, %{}, fn task, acc ->
      case DateTime.compare(task.retry_after, now) do
        :gt ->
          remaining_ms = max(0, DateTime.diff(task.retry_after, now, :millisecond))
          ref = Process.send_after(self(), {:retry_timer_expired, task.id}, remaining_ms)
          Map.put(acc, task.id, ref)

        _elapsed ->
          task
          |> Task.changeset(%{retry_after: nil})
          |> Repo.update!()

          acc
      end
    end)

    # coveralls-ignore-start
  rescue
    _error ->
      %{}
      # coveralls-ignore-stop
  end

  # coveralls-ignore-start (defensive table existence check on boot)
  defp tables_exist? do
    SQL.table_exists?(Repo, "tasks") and
      SQL.table_exists?(Repo, "projects") and
      SQL.table_exists?(Repo, "roles")
  rescue
    _error ->
      false
  end

  # coveralls-ignore-stop

  defp resolve_task_id(%Task{id: id}), do: id
  defp resolve_task_id(id) when is_binary(id), do: id
  defp resolve_task_id(_other), do: nil

  # coveralls-ignore-start (test sandbox fallback)
  defp allow_sandbox(caller_pid) do
    if Code.ensure_loaded?(Sandbox) and is_pid(caller_pid) do
      Sandbox.allow(Repo, caller_pid, self())
    end
  rescue
    _error -> :ok
  end

  # coveralls-ignore-stop
end
