defmodule Rail.Pipeline.Dispatcher do
  @moduledoc """
  GenServer responsible for queue pumping, concurrency management, and task dispatching.

  Subscribes to `"pipeline:changed"` PubSub events and runs periodic queue sweeps.
  When `AXIS_NO_DISPATCH=1` is set in the environment (or `:no_dispatch` in config),
  runs are not started, but the process maintains state and responds to pumps.
  """
  use GenServer

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Pipeline.Queue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  require Logger

  @default_tick_interval_ms 60_000
  # --- Client API ---
  @default_debounce_ms 100

  defstruct [
    :dispatch_disabled,
    :dispatch_hook,
    :tick_timer,
    :tick_interval_ms,
    :debounce_timer,
    :debounce_ms
  ]

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
    GenServer.call(server, :pump)
  end

  @doc """
  Attempts to immediately dispatch a specific task if slots are available.
  """
  def dispatch_now(server \\ __MODULE__, task_or_id) do
    GenServer.call(server, {:dispatch_now, task_or_id})
  end

  # --- GenServer Callbacks ---

  @doc """
  Returns whether dispatch is currently disabled (via `AXIS_NO_DISPATCH=1` or config).
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

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe, true) do
      Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    end

    env_disabled = System.get_env("AXIS_NO_DISPATCH") == "1"
    config_disabled = Application.get_env(:rail, :no_dispatch, false)
    dispatch_disabled = Keyword.get(opts, :dispatch_disabled, env_disabled or config_disabled)

    if dispatch_disabled do
      Logger.info("AXIS_NO_DISPATCH=1 is set. Dispatching is disabled.")
    end

    tick_interval_ms = Keyword.get(opts, :tick_interval_ms, @default_tick_interval_ms)
    debounce_ms = Keyword.get(opts, :debounce_ms, @default_debounce_ms)
    dispatch_hook = Keyword.get(opts, :dispatch_hook, &default_dispatch_hook/2)

    tick_timer =
      if Keyword.get(opts, :start_timer, true) do
        schedule_tick(tick_interval_ms)
      end

    state = %__MODULE__{
      dispatch_disabled: dispatch_disabled,
      dispatch_hook: dispatch_hook,
      tick_timer: tick_timer,
      tick_interval_ms: tick_interval_ms,
      debounce_timer: nil,
      debounce_ms: debounce_ms
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
  def handle_call({:dispatch_now, task_or_id}, {from_pid, _tag}, state) do
    allow_sandbox(from_pid)
    result = do_dispatch_now(task_or_id, state)
    {:reply, result, state}
  end

  @impl true
  def handle_cast(:pump, state) do
    _result = do_pump(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:pipeline_changed, _meta}, state) do
    if state.debounce_timer do
      Process.cancel_timer(state.debounce_timer)
    end

    # --- Internal Helpers ---

    timer = Process.send_after(self(), :debounced_pump, state.debounce_ms)
    {:noreply, %{state | debounce_timer: timer}}
  end

  @impl true
  def handle_info(:debounced_pump, state) do
    _result = do_pump(state)
    {:noreply, %{state | debounce_timer: nil}}
  end

  @impl true
  def handle_info(:tick, state) do
    _result = do_pump(state)
    tick_timer = schedule_tick(state.tick_interval_ms)
    {:noreply, %{state | tick_timer: tick_timer}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.tick_timer do
      Process.cancel_timer(state.tick_timer)
    end

    if state.debounce_timer do
      Process.cancel_timer(state.debounce_timer)
    end

    :ok
  end

  defp default_dispatch_hook(%Task{} = task, _role) do
    with {:ok, updated_task} <-
           task
           |> Task.changeset(%{stage_state: :running})
           |> Repo.update() do
      Rail.Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :dispatched})
      {:ok, updated_task}
    end
  end

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp do_pump(%__MODULE__{dispatch_disabled: true}) do
    Logger.info("AXIS_NO_DISPATCH=1 is set. Dispatching is disabled.")
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

  defp do_dispatch_now(_task_or_id, %__MODULE__{dispatch_disabled: true}) do
    {:error, :dispatch_disabled}
  end

  defp do_dispatch_now(task_or_id, %__MODULE__{dispatch_hook: dispatch_hook}) do
    case resolve_task(task_or_id) do
      %Task{stage_state: state} when state != :queued ->
        {:error, {:not_queued, state}}

      %Task{} = task ->
        stage_to_find = if task.is_rebasing, do: :engineer, else: task.stage

        case Rail.Roles.role_for_stage(task.project_id, stage_to_find) do
          {:ok, role} ->
            attempt_dispatch_single(task, role, dispatch_hook)

          {:error, _reason} ->
            {:error, {:no_role_for_stage, stage_to_find}}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp attempt_dispatch_single(task, role, dispatch_hook) do
    slots = Queue.available_slots(task.project_id, role)

    if slots > 0 do
      dispatch_hook.(task, role)
    else
      {:error, :no_available_slots}
    end
  end

  defp resolve_task(%Task{id: id}), do: Repo.get(Task, id)
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil

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
