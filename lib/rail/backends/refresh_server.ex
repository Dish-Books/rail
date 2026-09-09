defmodule Rail.Backends.RefreshServer do
  @moduledoc """
  GenServer that single-flights CLI usage refresh requests and periodically
  triggers refresh probes every 15 minutes.
  """
  use GenServer

  alias Rail.Backends

  @default_interval 15 * 60 * 1000

  @doc """
  Starts the RefreshServer.
  """
  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} ->
        GenServer.start_link(__MODULE__, opts)

      {:ok, name} ->
        GenServer.start_link(__MODULE__, opts, name: name)

      :error ->
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @doc """
  Triggers a single-flighted refresh. Concurrent callers join the in-flight run.
  """
  def refresh(opts) when is_list(opts) do
    refresh(__MODULE__, opts)
  end

  def refresh(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:refresh, opts}, 45_000)
  end

  @doc """
  Checks if the RefreshServer is alive and registered.
  """
  def running?(server \\ __MODULE__) do
    case server do
      pid when is_pid(pid) ->
        Process.alive?(pid)

      name ->
        case GenServer.whereis(name) do
          pid when is_pid(pid) -> Process.alive?(pid)
          nil -> false
        end
    end
  end

  # Callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    interval = Keyword.get(opts, :interval, @default_interval)

    timer_ref =
      if interval > 0 do
        {:ok, ref} = :timer.send_interval(interval, :periodic_tick)
        ref
      end

    {:ok, %{in_flight: nil, waiters: [], timer_ref: timer_ref, default_opts: opts}}
  end

  @impl true
  def handle_call({:refresh, opts}, from, state) do
    case state.in_flight do
      %Task{} ->
        {:noreply, %{state | waiters: [from | state.waiters]}}

      nil ->
        task = Task.async(fn -> Backends.refresh_usage(Keyword.put(opts, :direct, true)) end)
        {:noreply, %{state | in_flight: task, waiters: [from]}}
    end
  end

  @impl true
  def handle_info({ref, result}, %{in_flight: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    Enum.each(state.waiters, fn from ->
      GenServer.reply(from, result)
    end)

    {:noreply, %{state | in_flight: nil, waiters: []}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{in_flight: %Task{ref: ref}} = state) do
    Enum.each(state.waiters, fn from ->
      GenServer.reply(from, {:error, reason})
    end)

    {:noreply, %{state | in_flight: nil, waiters: []}}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:periodic_tick, state) do
    case state.in_flight do
      %Task{} ->
        {:noreply, state}

      nil ->
        task = Task.async(fn -> Backends.refresh_usage(Keyword.put(state.default_opts, :direct, true)) end)
        {:noreply, %{state | in_flight: task, waiters: []}}
    end
  end
end
