defmodule Rail.Triage.SlackSocket do
  @moduledoc """
  One Socket Mode connection to one Slack workspace, which is how its events
  reach Rail without a public URL.

  Slack hands out a websocket URL on the app-level token and pushes each event
  down it as an envelope. Every envelope is acked the moment it arrives, since
  Slack redelivers what is not acked within seconds, and only then handed on. A
  `disconnect` means Slack is about to close this connection, so a new one is
  opened while the old one is still read until Slack closes it. A connection
  that fails is retried with a backoff capped at 30 seconds.

  A connection can die without a word, so it is pinged, and reopened when nothing
  has come down it for a while. Every connection starts with a backfill of what
  was posted meanwhile, and the backfill runs again on an interval: a message it
  finds that this connection should have delivered means the socket is deaf, so it is reopened.
  """
  use GenServer

  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Slack
  alias Rail.Triage
  alias Rail.Triage.SocketRegistry

  require Logger

  @max_backoff to_timeout(second: 30)

  @timing %{
    ping_interval: to_timeout(second: 15),
    idle_timeout: to_timeout(second: 45),
    # How long a connection Slack said it would close is still read.
    drain: to_timeout(second: 30),
    backfill_interval: to_timeout(minute: 10),
    # How long Slack may take to deliver a message before a backfill finding it first counts as missed.
    delivery_grace: to_timeout(minute: 2)
  }

  defstruct [
    :workspace,
    :backoff,
    :initial_backoff,
    :timing,
    :active,
    :retry,
    :connected_at,
    :last_frame,
    :last_frame_at,
    :backfill,
    links: %{}
  ]

  @doc """
  Starts the connection for `:workspace`, registered under its id. `:backoff`
  is the first retry delay in milliseconds, and any of `#{inspect(Map.keys(@timing))}` overrides that wait.
  """
  def start_link(opts) do
    %SlackWorkspace{id: id} = Keyword.fetch!(opts, :workspace)
    # The registry value is the connection's state, which the Slack settings page shows.
    value = %{status: :connecting, last_frame_at: nil}
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {SocketRegistry, id, value}})
  end

  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :workspace).id}, start: {__MODULE__, :start_link, [opts]}}
  end

  @impl true
  def init(opts) do
    backoff = Keyword.get(opts, :backoff, 1_000)
    timing = Map.merge(@timing, Map.new(Keyword.take(opts, Map.keys(@timing))))
    Process.send_after(self(), :ping, timing.ping_interval)

    {:ok, %__MODULE__{workspace: opts[:workspace], backoff: backoff, initial_backoff: backoff, timing: timing},
     {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, %__MODULE__{} = state) do
    with {:ok, url} <- Slack.open_connection(state.workspace),
         {:ok, conn, websocket, ref, early} <- connect(URI.parse(url)) do
      %{
        state
        | links: Map.put(state.links, ref, %{conn: conn, websocket: websocket}),
          active: ref,
          connected_at: DateTime.utc_now(),
          last_frame: now()
      }
      |> status(:connected)
      |> backfill()
      |> receive_responses(ref, early)
    else
      {:error, reason} -> retry(state, reason)
    end
  end

  @impl true
  def handle_info(:reconnect, state), do: resume(%{state | retry: nil})

  def handle_info(:ping, %__MODULE__{active: active, timing: timing} = state) do
    Process.send_after(self(), :ping, timing.ping_interval)

    cond do
      is_nil(active) -> {:noreply, state}
      now() - state.last_frame >= timing.idle_timeout -> state |> drop(active, :idle_timeout) |> resume()
      true -> {:noreply, send_frame(state, active, {:ping, ""})}
    end
  end

  def handle_info({:drain, ref}, state), do: {:noreply, drop(state, ref, :drained)}

  # With no connection too: what the socket cannot deliver is still filed on the interval.
  def handle_info(:backfill, state), do: {:noreply, backfill(state)}

  def handle_info({task, filed}, %__MODULE__{backfill: {:running, task}} = state) do
    Process.demonitor(task, [:flush])
    state = await_backfill(state)
    connected = DateTime.to_unix(state.connected_at, :microsecond)
    delivered_by = System.os_time(:microsecond) - state.timing.delivery_grace * 1_000

    # Only what was posted on this connection's watch counts: older than that is the gap a backfill is for.
    missed =
      Enum.filter(filed, fn ts ->
        posted = round(String.to_float(ts) * 1_000_000)
        posted > connected and posted < delivered_by
      end)

    if missed != [] and is_reference(state.active) do
      Logger.warning("[slack] #{state.workspace.name} delivered nothing of #{length(missed)} messages posted")
      state |> drop(state.active, :silent) |> resume()
    else
      {:noreply, state}
    end
  end

  # coveralls-ignore-start (a backfill crashing, which takes Slack or the database failing mid-read)
  def handle_info({:DOWN, task, :process, _pid, _reason}, %__MODULE__{backfill: {:running, task}} = state) do
    {:noreply, await_backfill(state)}
  end

  # coveralls-ignore-stop

  def handle_info(message, %__MODULE__{} = state) do
    streamed =
      Enum.find_value(state.links, fn {ref, link} ->
        case Mint.WebSocket.stream(link.conn, message) do
          :unknown -> nil
          result -> {ref, result}
        end
      end)

    case streamed do
      {ref, {:ok, conn, responses}} ->
        receive_responses(%{state | links: Map.update!(state.links, ref, &%{&1 | conn: conn})}, ref, responses)

      {ref, {:error, _conn, reason, _responses}} ->
        state |> drop(ref, reason) |> resume()

      # coveralls-ignore-start (a message for a connection already closed, which nothing on this side can time)
      nil ->
        {:noreply, state}
        # coveralls-ignore-stop
    end
  end

  defp connect(%URI{scheme: scheme} = uri) do
    {http, ws} = if scheme == "wss", do: {:https, :wss}, else: {:http, :ws}
    path = if uri.query, do: "#{uri.path}?#{uri.query}", else: uri.path

    with {:ok, conn} <- Mint.HTTP.connect(http, uri.host, uri.port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws, conn, path, []),
         {:ok, conn, websocket, early} <- await_upgrade(conn, ref) do
      {:ok, conn, websocket, ref, early}
    else
      # coveralls-ignore-start (Mint reporting the failure against the connection mid-upgrade)
      {:error, _conn, reason} -> {:error, reason}
      # coveralls-ignore-stop
      {:error, reason} -> {:error, reason}
    end
  end

  # Only this connection's own messages are taken out of the mailbox: a plain `receive` would take
  # another caller's message, or one for the connection still draining. Slack may send its
  # first frames in the same packet as the upgrade, so everything read here is handed back to decode.
  defp await_upgrade(conn, ref, status \\ nil, headers \\ nil, early \\ [])

  defp await_upgrade(conn, ref, status, headers, early) when is_integer(status) and is_list(headers) do
    with {:ok, conn, websocket} <- Mint.WebSocket.new(conn, ref, status, headers) do
      {:ok, conn, websocket, early}
    end
  end

  defp await_upgrade(conn, ref, status, headers, early) do
    socket = Mint.HTTP.get_socket(conn)

    receive do
      {transport, ^socket, _data} = message when transport in [:tcp, :ssl] ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            status = status || find(responses, ref, :status)
            data = for {:data, ^ref, _data} = response <- responses, do: response
            await_upgrade(conn, ref, status, headers || find(responses, ref, :headers), early ++ data)

          # coveralls-ignore-start (a socket that breaks during the upgrade)
          {:error, _conn, reason, _responses} ->
            {:error, reason}
            # coveralls-ignore-stop
        end
    after
      # coveralls-ignore-next-line (a server that accepts the connection and never answers the upgrade)
      10_000 -> {:error, :upgrade_timeout}
    end
  end

  defp find(responses, ref, kind) do
    Enum.find_value(responses, fn
      {^kind, ^ref, value} -> value
      _other -> nil
    end)
  end

  defp receive_responses(state, ref, responses) do
    {state, chunks} = Enum.reduce(responses, {state, []}, &decode(&1, &2, ref))
    frames = chunks |> Enum.reverse() |> Enum.concat()
    state = if frames != [] and state.active == ref, do: heard_from(state), else: state
    frames |> Enum.reduce(state, &handle_frame(&1, &2, ref)) |> resume()
  end

  defp decode({:data, ref, data}, {%__MODULE__{links: links} = state, chunks}, ref) do
    link = Map.fetch!(links, ref)

    case Mint.WebSocket.decode(link.websocket, data) do
      {:ok, websocket, decoded} ->
        {%{state | links: %{links | ref => %{link | websocket: websocket}}}, [decoded | chunks]}

      # coveralls-ignore-next-line (a frame that is not a valid websocket frame)
      {:error, websocket, _reason} ->
        {%{state | links: %{links | ref => %{link | websocket: websocket}}}, chunks}
    end
  end

  # coveralls-ignore-next-line (a response after the upgrade that carries no frames, which Slack does not send)
  defp decode(_response, acc, _ref), do: acc

  defp heard_from(state) do
    status(%{state | last_frame: now(), last_frame_at: DateTime.utc_now()}, :connected)
  end

  defp handle_frame({:text, text}, state, ref) do
    case Jason.decode(text) do
      {:ok, %{"type" => "disconnect"}} -> retire(state, ref)
      {:ok, %{"type" => "hello"}} -> %{state | backoff: state.initial_backoff}
      {:ok, %{"envelope_id" => envelope_id} = envelope} -> ack(state, ref, envelope_id, envelope)
      _unreadable -> state
    end
  end

  defp handle_frame({:ping, data}, state, ref), do: send_frame(state, ref, {:pong, data})
  defp handle_frame({:close, _code, _reason}, state, ref), do: drop(state, ref, :closed)
  defp handle_frame(_frame, state, _ref), do: state

  defp ack(state, ref, envelope_id, envelope) do
    state = send_frame(state, ref, {:text, Jason.encode!(%{envelope_id: envelope_id})})

    with %{"type" => "events_api", "payload" => payload} <- envelope do
      workspace = state.workspace

      {:ok, _pid} =
        Task.Supervisor.start_child(Rail.TaskSupervisor, fn -> Triage.handle_slack_event(workspace, payload) end)
    end

    state
  end

  defp send_frame(%__MODULE__{links: links} = state, ref, frame) do
    with %{} = link <- links[ref],
         {:ok, websocket, data} <- Mint.WebSocket.encode(link.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(link.conn, ref, data) do
      %{state | links: %{links | ref => %{link | conn: conn, websocket: websocket}}}
    else
      # coveralls-ignore-start (a connection dropped earlier in the same read, or one that rejects a write)
      _failed ->
        state
        # coveralls-ignore-stop
    end
  end

  # Slack closes the connection some seconds after saying it will, and delivers down it until then,
  # so it is read until it closes or the drain runs out while a new one opens.
  defp retire(%__MODULE__{active: ref} = state, ref) do
    Logger.info("[slack] reconnecting #{state.workspace.name}: :disconnect")
    drain = Process.send_after(self(), {:drain, ref}, state.timing.drain)
    status(%{state | active: nil, links: Map.update!(state.links, ref, &Map.put(&1, :drain, drain))}, :connecting)
  end

  # coveralls-ignore-next-line (a second disconnect on a connection already draining)
  defp retire(state, _draining), do: state

  defp drop(%__MODULE__{links: links} = state, ref, reason) do
    case Map.pop(links, ref) do
      {%{conn: conn}, links} when state.active == ref ->
        Logger.info("[slack] reconnecting #{state.workspace.name}: #{inspect(reason)}")
        Mint.HTTP.close(conn)
        status(%{state | links: links, active: nil}, :connecting)

      {%{conn: conn} = link, links} ->
        with %{drain: drain} <- link, do: Process.cancel_timer(drain)
        Mint.HTTP.close(conn)
        %{state | links: links}

      # coveralls-ignore-start (a drain that ran out just as its connection closed)
      {nil, _links} ->
        state
        # coveralls-ignore-stop
    end
  end

  # A connection is opened whenever none is the active one, unless a retry is already waiting on its backoff.
  defp resume(%__MODULE__{active: nil, retry: nil} = state), do: {:noreply, state, {:continue, :connect}}
  defp resume(state), do: {:noreply, state}

  defp retry(%__MODULE__{backoff: backoff} = state, reason) do
    state = status(state, {:error, reason})
    Logger.warning("[slack] could not connect #{state.workspace.name}: #{inspect(reason)}")
    retry = Process.send_after(self(), :reconnect, backoff)
    {:noreply, %{state | retry: retry, backoff: min(backoff * 2, @max_backoff)}}
  end

  # Off this process, which has pings to answer and envelopes to ack while Slack's history is read.
  defp backfill(%__MODULE__{backfill: {:running, _task}} = state), do: state

  defp backfill(%__MODULE__{workspace: workspace} = state) do
    with {:waiting, timer} <- state.backfill, do: Process.cancel_timer(timer)
    task = Task.Supervisor.async_nolink(Rail.TaskSupervisor, fn -> Triage.backfill_slack_workspace(workspace) end)
    %{state | backfill: {:running, task.ref}}
  end

  defp await_backfill(state) do
    %{state | backfill: {:waiting, Process.send_after(self(), :backfill, state.timing.backfill_interval)}}
  end

  defp status(%__MODULE__{workspace: workspace, last_frame_at: last_frame_at} = state, status) do
    value = %{status: status, last_frame_at: last_frame_at}
    {_new, _old} = Registry.update_value(SocketRegistry, workspace.id, fn _previous -> value end)
    state
  end

  defp now, do: System.monotonic_time(:millisecond)
end
