defmodule Rail.Triage.SlackSocket do
  @moduledoc """
  One Socket Mode connection to one Slack workspace, which is how its events
  reach Rail without a public URL.

  Slack hands out a websocket URL on the app-level token and pushes each event
  down it as an envelope. Every envelope is acked the moment it arrives, since
  Slack redelivers what is not acked within seconds, and only then handed on. A
  `disconnect` means Slack is about to close this connection, so a new one is
  opened; a connection that fails is retried with a backoff capped at 30 seconds.
  """
  use GenServer

  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Slack
  alias Rail.Triage

  require Logger

  @max_backoff to_timeout(second: 30)

  defstruct [:workspace, :conn, :websocket, :ref, :backoff, :initial_backoff]

  @doc """
  Starts the connection for `:workspace`, registered under its id. `:backoff`
  is the first retry delay in milliseconds.
  """
  def start_link(opts) do
    %SlackWorkspace{id: id} = Keyword.fetch!(opts, :workspace)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {Rail.Triage.SocketRegistry, id}})
  end

  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :workspace).id}, start: {__MODULE__, :start_link, [opts]}}
  end

  @impl true
  def init(opts) do
    backoff = Keyword.get(opts, :backoff, 1_000)
    {:ok, %__MODULE__{workspace: opts[:workspace], backoff: backoff, initial_backoff: backoff}, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, %__MODULE__{} = state) do
    with {:ok, url} <- Slack.open_connection(state.workspace),
         {:ok, conn, websocket, ref} <- connect(URI.parse(url)) do
      {:noreply, %{state | conn: conn, websocket: websocket, ref: ref}}
    else
      {:error, reason} -> retry(state, reason)
    end
  end

  @impl true
  def handle_info(:reconnect, state), do: {:noreply, state, {:continue, :connect}}

  def handle_info(message, %__MODULE__{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        {state, chunks} = Enum.reduce(responses, {%{state | conn: conn}, []}, &decode/2)
        frames = chunks |> Enum.reverse() |> Enum.concat()
        Enum.reduce_while(frames, {:noreply, state}, fn frame, {:noreply, state} -> handle_frame(frame, state) end)

      {:error, conn, reason, _responses} ->
        reopen(%{state | conn: conn}, reason)

      # coveralls-ignore-start (a message for a connection already replaced, which nothing on this side can time)
      :unknown ->
        {:noreply, state}
        # coveralls-ignore-stop
    end
  end

  # coveralls-ignore-start (a message arriving between connections, which nothing on this side can time)
  def handle_info(_message, state), do: {:noreply, state}
  # coveralls-ignore-stop

  defp connect(%URI{scheme: scheme} = uri) do
    {http, ws} = if scheme == "wss", do: {:https, :wss}, else: {:http, :ws}
    path = if uri.query, do: "#{uri.path}?#{uri.query}", else: uri.path

    with {:ok, conn} <- Mint.HTTP.connect(http, uri.host, uri.port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws, conn, path, []),
         {:ok, conn, websocket} <- await_upgrade(conn, ref) do
      {:ok, conn, websocket, ref}
    else
      # coveralls-ignore-start (Mint reporting the failure against the connection mid-upgrade)
      {:error, _conn, reason} -> {:error, reason}
      # coveralls-ignore-stop
      {:error, reason} -> {:error, reason}
    end
  end

  # Only the socket's own messages are taken out of the mailbox, as in `Rail.Tools.Browser`.
  defp await_upgrade(conn, ref, status \\ nil, headers \\ nil)

  defp await_upgrade(conn, ref, status, headers) when is_integer(status) and is_list(headers) do
    Mint.WebSocket.new(conn, ref, status, headers)
  end

  defp await_upgrade(conn, ref, status, headers) do
    receive do
      {transport, _socket, _data} = message when transport in [:tcp, :ssl] ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            await_upgrade(conn, ref, status || find(responses, ref, :status), headers || find(responses, ref, :headers))

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

  defp decode({:data, ref, data}, {%__MODULE__{ref: ref} = state, chunks}) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, decoded} -> {%{state | websocket: websocket}, [decoded | chunks]}
      # coveralls-ignore-next-line (a frame that is not a valid websocket frame)
      {:error, websocket, _reason} -> {%{state | websocket: websocket}, chunks}
    end
  end

  # coveralls-ignore-start (the request finishing rather than a close frame, the other shape a closed socket takes)
  defp decode({:done, _ref}, {state, chunks}), do: {state, [[{:close, 1000, ""}] | chunks]}
  defp decode(_response, acc), do: acc
  # coveralls-ignore-stop

  defp handle_frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => "disconnect"}} -> {:halt, reopen(state, :disconnect)}
      {:ok, %{"type" => "hello"}} -> {:cont, {:noreply, %{state | backoff: state.initial_backoff}}}
      {:ok, %{"envelope_id" => envelope_id} = envelope} -> {:cont, {:noreply, ack(state, envelope_id, envelope)}}
      _unreadable -> {:cont, {:noreply, state}}
    end
  end

  defp handle_frame({:ping, data}, state), do: {:cont, {:noreply, send_frame(state, {:pong, data})}}
  defp handle_frame({:close, _code, _reason}, state), do: {:halt, reopen(state, :closed)}
  defp handle_frame(_frame, state), do: {:cont, {:noreply, state}}

  defp ack(state, envelope_id, envelope) do
    state = send_frame(state, {:text, Jason.encode!(%{envelope_id: envelope_id})})

    with %{"type" => "events_api", "payload" => payload} <- envelope do
      workspace = state.workspace

      {:ok, _pid} =
        Task.Supervisor.start_child(Rail.TaskSupervisor, fn -> Triage.handle_slack_event(workspace, payload) end)
    end

    state
  end

  defp send_frame(%__MODULE__{} = state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      %{state | conn: conn, websocket: websocket}
    else
      # coveralls-ignore-start (a socket that rejects a write without having closed)
      _failed ->
        state
        # coveralls-ignore-stop
    end
  end

  defp reopen(%__MODULE__{conn: conn} = state, reason) do
    Logger.info("[slack] reconnecting #{state.workspace.name}: #{inspect(reason)}")
    Mint.HTTP.close(conn)
    {:noreply, %{state | conn: nil, websocket: nil, ref: nil}, {:continue, :connect}}
  end

  defp retry(%__MODULE__{backoff: backoff} = state, reason) do
    Logger.warning("[slack] could not connect #{state.workspace.name}: #{inspect(reason)}")
    Process.send_after(self(), :reconnect, backoff)
    {:noreply, %{state | backoff: min(backoff * 2, @max_backoff)}}
  end
end
