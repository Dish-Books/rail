defmodule Rail.Periodic do
  @moduledoc """
  GenServer responsible for periodic background execution of pipeline tasks:
  1. Mergeability + Demo Freshness (every 2m)
  2. Linear Sync (every 5m)
  3. Backend Usage Probes (every 15m)
  4. Run Events Pruning (daily / 30-day retention)

  Each tick executes inside `Task.Supervisor` and is single-flighted per tick name:
  if a previous tick of the same type is still running, the new tick is skipped.
  """

  use GenServer

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  require Logger

  @default_mergeability_interval_ms 120_000
  @default_linear_sync_interval_ms 300_000
  @default_usage_probes_interval_ms 900_000
  @default_run_events_prune_interval_ms 86_400_000
  @default_retention_days 30
  @default_task_supervisor Rail.TaskSupervisor

  @all_ticks [
    :mergeability_demo_freshness,
    :linear_sync,
    :usage_probes,
    :run_events_prune
  ]

  defstruct [
    :task_supervisor,
    :retention_days,
    :backend_opts,
    running_tasks: %{},
    running_ticks: MapSet.new(),
    waiters: %{},
    timers: %{},
    intervals: %{}
  ]

  # --- Client API ---

  @doc """
  Starts the Periodic GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    if is_nil(name) do
      GenServer.start_link(__MODULE__, opts)
    else
      GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Triggers a specific tick either synchronously (awaiting completion) or asynchronously.
  Returns `{:ok, result}` on success, or `{:skipped, :already_running}` if the tick
  is already in progress.
  """
  def trigger_tick(server \\ __MODULE__, tick_name, opts \\ []) do
    canonical = canonical_tick(tick_name)

    if canonical in @all_ticks do
      timeout = Keyword.get(opts, :timeout, 60_000)
      GenServer.call(server, {:trigger_tick, canonical, opts}, timeout)
    else
      {:error, {:unknown_tick, tick_name}}
    end
  end

  @doc """
  Convenience helper for triggering an immediate synchronous tick.
  """
  def tick_now(server \\ __MODULE__, tick_name) do
    trigger_tick(server, tick_name, [])
  end

  @doc """
  Returns a list of tick names currently executing.
  """
  def running_ticks(server \\ __MODULE__) do
    GenServer.call(server, :running_ticks)
  end

  @doc """
  Returns the active tick intervals map.
  """
  def intervals(server \\ __MODULE__) do
    GenServer.call(server, :intervals)
  end

  @doc """
  Executes the logic for a tick directly in the calling process.
  """
  def execute_tick(tick_name, opts \\ []) do
    if opts[:crash] do
      raise "intentional test crash"
    end

    case canonical_tick(tick_name) do
      :mergeability_demo_freshness ->
        execute_mergeability_demo_freshness(opts)

      :linear_sync ->
        execute_linear_sync(opts)

      :usage_probes ->
        execute_usage_probes(opts)

      :run_events_prune ->
        execute_run_events_prune(opts)

      other ->
        {:error, {:unknown_tick, other}}
    end
  end

  @doc """
  Normalizes tick aliases to canonical tick names.
  """
  def canonical_tick(:mergeability), do: :mergeability_demo_freshness
  def canonical_tick(:mergeability_demo_freshness), do: :mergeability_demo_freshness
  def canonical_tick(:linear_sync), do: :linear_sync
  def canonical_tick(:usage_probes), do: :usage_probes
  def canonical_tick(:run_events_prune), do: :run_events_prune
  def canonical_tick(:prune), do: :run_events_prune
  def canonical_tick(:prune_run_events), do: :run_events_prune
  def canonical_tick(other), do: other

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    intervals = build_intervals(opts)
    auto_start = Keyword.get(opts, :auto_start, default_auto_start?())
    retention_days = Keyword.get(opts, :retention_days, @default_retention_days)
    task_sup = Keyword.get(opts, :task_supervisor, @default_task_supervisor)
    backend_opts = Keyword.get(opts, :backend_opts, [])

    timers =
      if auto_start do
        schedule_timers(intervals)
      else
        %{}
      end

    state = %__MODULE__{
      task_supervisor: task_sup,
      retention_days: retention_days,
      backend_opts: backend_opts,
      running_tasks: %{},
      running_ticks: MapSet.new(),
      waiters: %{},
      timers: timers,
      intervals: intervals
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:trigger_tick, canonical, opts}, from, state) do
    if MapSet.member?(state.running_ticks, canonical) do
      {:reply, {:skipped, :already_running}, state}
    else
      async? = Keyword.get(opts, :async, false)
      {caller_pid, _tag} = from
      pids_to_allow = [self(), caller_pid]

      task =
        spawn_tick_task(
          state.task_supervisor,
          canonical,
          opts,
          state.retention_days,
          state.backend_opts,
          pids_to_allow
        )

      new_running_tasks = Map.put(state.running_tasks, task.ref, canonical)
      new_running_ticks = MapSet.put(state.running_ticks, canonical)

      if async? do
        {:reply, :ok, %{state | running_tasks: new_running_tasks, running_ticks: new_running_ticks}}
      else
        new_waiters = Map.update(state.waiters, canonical, [from], &[from | &1])

        {:noreply,
         %{
           state
           | running_tasks: new_running_tasks,
             running_ticks: new_running_ticks,
             waiters: new_waiters
         }}
      end
    end
  end

  @impl true
  def handle_call(:running_ticks, _from, state) do
    {:reply, MapSet.to_list(state.running_ticks), state}
  end

  @impl true
  def handle_call(:intervals, _from, state) do
    {:reply, state.intervals, state}
  end

  @impl true
  def handle_info({:tick, tick_name}, state) do
    canonical = canonical_tick(tick_name)

    if MapSet.member?(state.running_ticks, canonical) do
      Logger.debug("Periodic tick #{canonical} skipped: previous run is still in progress.")
      {:noreply, state}
    else
      task =
        spawn_tick_task(
          state.task_supervisor,
          canonical,
          [],
          state.retention_days,
          state.backend_opts,
          [self()]
        )

      new_running_tasks = Map.put(state.running_tasks, task.ref, canonical)
      new_running_ticks = MapSet.put(state.running_ticks, canonical)

      {:noreply, %{state | running_tasks: new_running_tasks, running_ticks: new_running_ticks}}
    end
  end

  @impl true
  def handle_info({ref, result}, %{running_tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    canonical = Map.fetch!(tasks, ref)

    notify_waiters(state.waiters, canonical, result)

    new_running_tasks = Map.delete(state.running_tasks, ref)
    new_running_ticks = MapSet.delete(state.running_ticks, canonical)
    new_waiters = Map.delete(state.waiters, canonical)

    {:noreply,
     %{
       state
       | running_tasks: new_running_tasks,
         running_ticks: new_running_ticks,
         waiters: new_waiters
     }}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running_tasks: tasks} = state) when is_map_key(tasks, ref) do
    canonical = Map.fetch!(tasks, ref)
    Logger.error("Periodic tick #{canonical} task terminated unexpectedly: #{inspect(reason)}")

    notify_waiters(state.waiters, canonical, {:error, reason})

    new_running_tasks = Map.delete(state.running_tasks, ref)
    new_running_ticks = MapSet.delete(state.running_ticks, canonical)
    new_waiters = Map.delete(state.waiters, canonical)

    {:noreply,
     %{
       state
       | running_tasks: new_running_tasks,
         running_ticks: new_running_ticks,
         waiters: new_waiters
     }}
  end

  @impl true
  def handle_info(_other, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.timers, fn {_tick, ref} ->
      :timer.cancel(ref)
    end)

    :ok
  end

  # --- Private Helpers ---

  defp default_auto_start? do
    periodic_config = Application.get_env(:rail, :periodic, [])
    Keyword.get(periodic_config, :auto_start, true)
  end

  defp build_intervals(opts) do
    custom_intervals = Keyword.get(opts, :intervals, %{})

    %{
      mergeability_demo_freshness:
        resolve_interval(
          custom_intervals[:mergeability_demo_freshness] || opts[:mergeability_interval_ms],
          @default_mergeability_interval_ms
        ),
      linear_sync:
        resolve_interval(
          custom_intervals[:linear_sync] || opts[:linear_sync_interval_ms],
          @default_linear_sync_interval_ms
        ),
      usage_probes:
        resolve_interval(
          custom_intervals[:usage_probes] || opts[:usage_probes_interval_ms],
          @default_usage_probes_interval_ms
        ),
      run_events_prune:
        resolve_interval(
          custom_intervals[:run_events_prune] || opts[:prune_interval_ms],
          @default_run_events_prune_interval_ms
        )
    }
  end

  defp resolve_interval(val, _default) when is_integer(val) and val >= 0, do: val
  defp resolve_interval(_other, default), do: default

  defp schedule_timers(intervals) do
    Enum.reduce(intervals, %{}, fn {tick, interval}, acc ->
      if interval > 0 do
        {:ok, ref} = :timer.send_interval(interval, {:tick, tick})
        Map.put(acc, tick, ref)
      else
        acc
      end
    end)
  end

  defp spawn_tick_task(supervisor, canonical, opts, default_retention, backend_opts, pids) do
    Elixir.Task.Supervisor.async_nolink(supervisor, fn ->
      allow_sandbox(pids)
      allow_test_mocks(pids)

      merged_opts =
        opts
        |> Keyword.put_new(:retention_days, default_retention)
        |> Keyword.merge(backend_opts)

      execute_tick(canonical, merged_opts)
    end)
  end

  defp notify_waiters(waiters_map, canonical, reply) do
    case Map.get(waiters_map, canonical) do
      list when is_list(list) ->
        Enum.each(list, fn from -> GenServer.reply(from, reply) end)

      nil ->
        :ok
    end
  end

  defp execute_mergeability_demo_freshness(opts) do
    query =
      from t in Task,
        where: not is_nil(t.pr_number) and t.stage != :merged and is_nil(t.merged_at),
        order_by: [asc: t.id]

    tasks = Repo.all(query)

    results =
      Enum.map(tasks, fn task ->
        refresh_single_task(task, opts)
      end)

    {:ok, %{processed: length(tasks), results: results}}
  end

  defp refresh_single_task(task, opts) do
    case Rail.Pipeline.refresh_mergeability(task, opts) do
      {:ok, updated_task} ->
        fresh_res = Rail.Pipeline.refresh_demo_freshness(updated_task, opts)
        {task.id, {:ok, {:ok, updated_task}, fresh_res}}

      {:error, _reason} = err ->
        fresh_res = Rail.Pipeline.refresh_demo_freshness(task, opts)
        {task.id, {:ok, err, fresh_res}}
    end

    # coveralls-ignore-start (defensive error handling for unexpected exceptions in task refresh)
  rescue
    e ->
      {task.id, {:error, Exception.message(e)}}
  catch
    :exit, reason ->
      {task.id, {:error, {:exit, reason}}}
      # coveralls-ignore-stop
  end

  defp execute_linear_sync(opts) do
    query =
      from p in Project,
        where:
          p.active == true and
            ((not is_nil(p.linear_team_id) and p.linear_team_id != "") or
               not is_nil(p.linear_workspace_id)),
        order_by: [asc: p.id]

    projects = Repo.all(query)
    scope = Keyword.get(opts, :scope) || Scope.for_system()

    results =
      Enum.map(projects, fn project ->
        sync_single_project(scope, project)
      end)

    {:ok, %{processed: length(projects), results: results}}
  end

  defp sync_single_project(scope, project) do
    case Rail.Issues.sync_issues(scope, project) do
      {:ok, issues} -> {project.id, {:ok, issues}}
      {:error, reason} -> {project.id, {:error, reason}}
    end

    # coveralls-ignore-start (defensive error handling for unexpected exceptions in project sync)
  rescue
    e ->
      {project.id, {:error, Exception.message(e)}}
  catch
    :exit, reason ->
      {project.id, {:error, {:exit, reason}}}
      # coveralls-ignore-stop
  end

  defp execute_usage_probes(opts) do
    scope = Keyword.get(opts, :scope) || Scope.for_system()
    Rail.Backends.refresh_usage(scope, opts)
  end

  defp execute_run_events_prune(opts) do
    Rail.Runs.prune_run_events(opts)
  end

  # coveralls-ignore-start (test sandbox and mock fallback)
  defp allow_sandbox(pids) when is_list(pids) do
    if Code.ensure_loaded?(Sandbox) do
      Enum.each(pids, fn pid ->
        if is_pid(pid) do
          allow_one(pid)
        end
      end)
    end
  end

  defp allow_one(pid) do
    Sandbox.allow(Repo, pid, self())
  rescue
    _error -> :ok
  end

  defp allow_test_mocks(pids) when is_list(pids) do
    if Code.ensure_loaded?(Req.Test) do
      Enum.each(pids, fn pid ->
        if is_pid(pid) do
          try do
            Req.Test.allow(Rail.GitHub, pid, self())
          rescue
            _error -> :ok
          end

          try do
            Req.Test.allow(Rail.Linear, pid, self())
          rescue
            _error -> :ok
          end
        end
      end)
    end
  rescue
    _error -> :ok
  end

  # coveralls-ignore-stop
end
