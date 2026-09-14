defmodule Rail.Pipeline.TaskActionRunner do
  @moduledoc """
  Coordinates in-flight actions per task.

  Ensures single-flight execution so repeated clicks cannot double-fire, applies
  timeouts so hung work gives up, tracks what is in flight, and cleans up lock
  state on exit.
  """

  use GenServer

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Repo

  @name __MODULE__

  @doc """
  Starts the action runner process.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns whether the task currently has an in-flight action running.
  """
  def is_busy?(task_id) when is_binary(task_id), do: is_busy?(@name, task_id)

  def is_busy?(server, task_id) when is_binary(task_id) do
    GenServer.call(server, {:is_busy?, task_id})
  end

  @doc """
  Returns the action kind currently running on the task, or nil if none.
  """
  def running_on(task_id) when is_binary(task_id), do: running_on(@name, task_id)

  def running_on(server, task_id) when is_binary(task_id) do
    GenServer.call(server, {:running_on, task_id})
  end

  @doc """
  Attempts to acquire the single-flight action lock for the given task and kind.
  Returns `:ok` or `{:error, :busy}`.
  """
  def start_action(task_id, kind) when is_binary(task_id) and is_atom(kind) do
    start_action(@name, task_id, kind)
  end

  def start_action(server, task_id, kind) when is_binary(task_id) and is_atom(kind) do
    GenServer.call(server, {:start_action, task_id, kind})
  end

  @doc """
  Releases the action lock for the task. The outcome is the caller's to report:
  an error belongs to the run that produced it, not to the task.
  """
  def finish_action(task_id, kind, outcome) when is_binary(task_id) and is_atom(kind) do
    finish_action(@name, task_id, kind, outcome)
  end

  def finish_action(server, task_id, kind, outcome) when is_binary(task_id) and is_atom(kind) do
    GenServer.call(server, {:finish_action, task_id, kind, outcome})
  end

  @doc """
  Clears any in-flight record for the task without writing an error (e.g. on cleanup).
  """
  def forget(task_id) when is_binary(task_id), do: forget(@name, task_id)

  def forget(server, task_id) when is_binary(task_id) do
    GenServer.call(server, {:forget, task_id})
  end

  @doc """
  Runs `work_fn` under the single-flight lock for `task_id` with `kind`.
  Applies timeout handling and guarantees lock release on completion or failure.
  """
  def run(task_id, kind, work_fn) when is_binary(task_id) and is_atom(kind) and is_function(work_fn, 0) do
    run(@name, task_id, kind, work_fn, [])
  end

  def run(task_id, kind, work_fn, opts)
      when is_binary(task_id) and is_atom(kind) and is_function(work_fn, 0) and is_list(opts) do
    run(@name, task_id, kind, work_fn, opts)
  end

  def run(server, task_id, kind, work_fn, opts)
      when is_binary(task_id) and is_atom(kind) and is_function(work_fn, 0) and is_list(opts) do
    case start_action(server, task_id, kind) do
      :ok ->
        timeout = Keyword.get(opts, :timeout, timeout_for(kind, opts))
        caller = self()

        task =
          Task.async(fn ->
            allow_sandbox(caller)
            work_fn.()
          end)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, {:ok, result}} ->
            finish_action(server, task_id, kind, {:ok, result})
            {:ok, result}

          {:ok, {:error, reason}} ->
            finish_action(server, task_id, kind, {:error, reason})
            {:error, reason}

          {:ok, result} ->
            finish_action(server, task_id, kind, {:ok, result})
            {:ok, result}

          {:exit, reason} ->
            finish_action(server, task_id, kind, {:error, reason})
            {:error, reason}

          nil ->
            finish_action(server, task_id, kind, {:error, :timeout})
            {:error, :timeout}
        end

      {:error, :busy} ->
        {:error, :busy}
    end
  end

  @doc """
  Returns whether this action should render a visual spinner while running.
  """

  # Server Callbacks

  def shows_progress?(kind) when is_atom(kind) do
    kind in [:merge, :cleanup, :mark_ready]
  end

  def shows_progress?(_other), do: false

  @doc """
  Returns default timeout in milliseconds for an action kind.
  """
  def timeout_for(kind, opts \\ [])

  def timeout_for(kind, opts) when is_atom(kind) and is_list(opts) do
    case Keyword.get(opts, :timeout) do
      timeout when is_integer(timeout) and timeout > 0 ->
        timeout

      nil ->
        case kind do
          :merge -> 180_000
          :cleanup -> 120_000
          :mark_ready -> 60_000
          _other -> 60_000
        end
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{running: %{}}}
  end

  @impl true
  def handle_call({:is_busy?, task_id}, _from, state) do
    busy? = Map.has_key?(state.running, task_id)
    {:reply, busy?, state}
  end

  @impl true
  def handle_call({:running_on, task_id}, _from, state) do
    kind = Map.get(state.running, task_id)
    {:reply, kind, state}
  end

  @impl true
  def handle_call({:start_action, task_id, kind}, {from_pid, _ref}, state) do
    allow_sandbox(from_pid)

    if Map.has_key?(state.running, task_id) do
      {:reply, {:error, :busy}, state}
    else
      {:reply, :ok, %{state | running: Map.put(state.running, task_id, kind)}}
    end
  end

  @impl true
  def handle_call({:finish_action, task_id, _kind, _outcome}, {from_pid, _ref}, state) do
    allow_sandbox(from_pid)

    {:reply, :ok, %{state | running: Map.delete(state.running, task_id)}}
  end

  @impl true
  def handle_call({:forget, task_id}, _from, state) do
    new_running = Map.delete(state.running, task_id)
    {:reply, :ok, %{state | running: new_running}}
  end

  # Private Helpers

  # coveralls-ignore-start
  defp allow_sandbox(caller_pid) do
    if Code.ensure_loaded?(Sandbox) and is_pid(caller_pid) do
      Sandbox.allow(Repo, caller_pid, self())
    end
  rescue
    _error -> :ok
  end

  # coveralls-ignore-stop
end
