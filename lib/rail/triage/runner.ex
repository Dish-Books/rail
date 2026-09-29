defmodule Rail.Triage.Runner do
  @moduledoc """
  Runs triage passes on this node, one at a time per thread and as many threads
  at once as there are.

  It hears of a pass owed as `{:triage_scheduled, thread_id, delay_ms}` on
  `"triage"`. A thread already waiting on its timer keeps it, so a burst of
  messages is read once, and one scheduled while its pass runs gets another pass
  as soon as that one ends.

  Passes are linked to it, so none outlives it. When it starts, every lock a
  thread holds belonged to a pass that died with the last one, so it clears
  them and schedules every thread still Triaging. A deploy costs a pass
  restarting, not a thread stranded. Turned off with `config :rail, :triage_runner, false`.
  """
  use GenServer

  import Ecto.Query
  import Rail.Triage.Utils.SettleThread

  alias Rail.Repo
  alias Rail.Triage
  alias Rail.Triage.Schemas.Thread

  require Logger

  @doc """
  Starts the runner unless it is switched off. Takes `:enabled` to override the
  config, and `:retry_after`, how long a pass that found its thread locked waits.
  """
  def start_link(opts \\ []) do
    if Keyword.get(opts, :enabled, Application.get_env(:rail, :triage_runner, true)) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Phoenix.PubSub.subscribe(Rail.PubSub, "triage")
    state = %{timers: %{}, running: %{}, again: MapSet.new(), retry_after: Keyword.get(opts, :retry_after, 30_000)}
    {:ok, state, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    Repo.update_all(from(t in Thread, where: not is_nil(t.triage_started_at)),
      set: [triage_started_at: nil, mcp_token_hash: nil]
    )

    owed = Repo.all(from t in Thread, where: t.status == :triaging, select: t.id)
    {:noreply, Enum.reduce(owed, state, &schedule(&2, &1, 0))}
  end

  @impl true
  def handle_info({:triage_scheduled, thread_id, delay}, state), do: {:noreply, schedule(state, thread_id, delay)}

  def handle_info({:run, thread_id}, state) do
    task = Task.Supervisor.async(Rail.TaskSupervisor, fn -> run(thread_id) end)
    state = %{state | timers: Map.delete(state.timers, thread_id), running: Map.put(state.running, task.ref, thread_id)}
    {:noreply, state}
  end

  def handle_info({ref, result}, %{running: running} = state) when is_map_key(running, ref) do
    Process.demonitor(ref, [:flush])
    {thread_id, state} = finish(state, ref)

    case result do
      {:snooze, _seconds} -> {:noreply, schedule(state, thread_id, state.retry_after)}
      :ok -> {:noreply, again(state, thread_id)}
    end
  end

  # A pass that crashed never let go of its thread, so that happens here, with the reason
  # shown where "Triage again" can retry it.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: running} = state) when is_map_key(running, ref) do
    {thread_id, state} = finish(state, ref)
    Logger.error("[triage] pass on #{thread_id} crashed: #{inspect(reason)}")

    with %Thread{} = thread <- Repo.get(Thread, thread_id) do
      thread
      |> Ecto.Changeset.change(error: "Triage crashed: #{inspect(reason)}", triage_started_at: nil, mcp_token_hash: nil)
      |> Repo.update!()

      {:ok, _settled} = settle_thread(thread)
    end

    {:noreply, again(state, thread_id)}
  end

  # The exit of a linked pass, already handled as its `:DOWN`, and whatever else "triage" carries.
  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(state, thread_id, delay) do
    cond do
      thread_id in Map.values(state.running) ->
        %{state | again: MapSet.put(state.again, thread_id)}

      Map.has_key?(state.timers, thread_id) ->
        state

      true ->
        %{state | timers: Map.put(state.timers, thread_id, Process.send_after(self(), {:run, thread_id}, delay))}
    end
  end

  defp finish(state, ref) do
    {thread_id, running} = Map.pop!(state.running, ref)
    {thread_id, %{state | running: running}}
  end

  defp again(state, thread_id) do
    if MapSet.member?(state.again, thread_id) do
      schedule(%{state | again: MapSet.delete(state.again, thread_id)}, thread_id, 0)
    else
      state
    end
  end

  defp run(thread_id) do
    case Repo.get(Thread, thread_id) do
      %Thread{} = thread -> Triage.triage_thread(thread)
      nil -> :ok
    end
  end
end
