defmodule Rail.Tools.Browser do
  @moduledoc """
  One websocket to one Chrome, speaking the DevTools protocol.

  Everything Rail does to a browser goes through here: a command is a JSON frame
  with an id, and the reply carrying that id is the answer. Calls are answered out
  of order, so a caller waits on its own id rather than on the next frame to
  arrive, and a command whose reply never comes times out without taking the
  connection down with it.

  Chrome also talks without being asked - a screencast frame, a console message, a
  failed request - and those arrive as events with no id. They go to whoever
  subscribed, which is how the panel watches a pass without the agent paying for
  it.

  The socket is attached to a target rather than to the browser as a whole: a
  command carries a `:session` so it reaches the tab QA is driving, not some
  other tab the same Chrome happens to have open. That is deliberately not spelt
  `sessionId`, which is a name some methods use for something else entirely -
  acknowledging a screencast frame addresses the tab and names the frame, and both
  of them would otherwise be the same key.
  """
  use GenServer, restart: :transient

  require Logger

  @call_timeout 30_000

  defstruct [:conn, :websocket, :ref, :url, :next_id, :pending, :subscribers, :buffer]

  @doc """
  Connects to the DevTools websocket at `url` and returns the connection.

  `opts` takes `:name` to register it and `:subscribe` for a process that should
  receive `{:cdp_event, method, params}` for everything Chrome says unprompted.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Sends `method` with `params` and returns `{:ok, result}` when Chrome answers.

  `params` may carry `:session` to address a target attached to this socket. A
  method Chrome refuses comes back as `{:error, message}` rather than raising: a
  page that navigated out from under a command is ordinary, not exceptional.
  """
  def call(connection, method, params \\ %{}, timeout \\ @call_timeout) do
    GenServer.call(connection, {:call, method, params}, timeout + 1_000)
  end

  @doc """
  Sends `method` without waiting for Chrome to answer it.

  For the commands whose answer carries nothing anybody reads and which happen
  often enough that waiting would matter - acknowledging a screencast frame, which
  arrives many times a second and holds up the next frame until it is sent.
  """
  def cast(connection, method, params \\ %{}) do
    GenServer.cast(connection, {:cast, method, params})
  end

  @doc """
  Adds `pid` to the processes told about events Chrome sends unprompted.
  """
  def subscribe(connection, pid) do
    GenServer.call(connection, {:subscribe, pid})
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      url: opts[:url],
      next_id: 1,
      pending: %{},
      subscribers: List.wrap(opts[:subscribe]),
      buffer: ""
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, %__MODULE__{url: url} = state) do
    uri = URI.parse(url)

    with {:ok, conn} <- Mint.HTTP.connect(:http, uri.host, uri.port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, path(uri), []),
         {:ok, conn, websocket} <- await_upgrade(conn, ref) do
      {:noreply, %{state | conn: conn, websocket: websocket, ref: ref}}
    else
      {:error, reason} ->
        {:stop, {:cdp_connect_failed, reason}, state}

      # coveralls-ignore-start (Mint reporting the failure against the
      # connection, which needs a socket that breaks mid-upgrade)
      {:error, _conn, reason} ->
        {:stop, {:cdp_connect_failed, reason}, state}
        # coveralls-ignore-stop
    end
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, %__MODULE__{} = state) do
    {:reply, :ok, %{state | subscribers: Enum.uniq([pid | state.subscribers])}}
  end

  def handle_call({:call, method, params}, from, %__MODULE__{} = state) do
    id = state.next_id
    frame = Jason.encode!(command(id, method, params))

    case send_frame(state, {:text, frame}) do
      {:ok, state} ->
        {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}}

      # coveralls-ignore-start (a socket that refuses a frame it has not already
      # closed, which ends the connection rather than returning here)
      {:error, reason} ->
        {:reply, {:error, reason}, state}
        # coveralls-ignore-stop
    end
  end

  # Nothing is recorded as pending, so Chrome's reply is dropped on arrival the
  # same way a reply to a command that timed out is.
  @impl true
  def handle_cast({:cast, method, params}, %__MODULE__{} = state) do
    id = state.next_id
    frame = Jason.encode!(command(id, method, params))

    case send_frame(state, {:text, frame}) do
      {:ok, state} ->
        {:noreply, %{state | next_id: id + 1}}

      # coveralls-ignore-start (as above; nothing here waits on the answer either way)
      {:error, _reason} ->
        {:noreply, %{state | next_id: id + 1}}
        # coveralls-ignore-stop
    end
  end

  @impl true
  def handle_info(message, %__MODULE__{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state = Enum.reduce(responses, %{state | conn: conn}, &handle_response/2)

        # Chrome exiting closes the socket. A connection to a browser that is
        # gone would go on accepting commands and time out on every one of them,
        # so it ends here and whoever is holding it is told.
        if Enum.any?(responses, &closed?/1), do: {:stop, :normal, state}, else: {:noreply, state}

      # The same thing arriving as an error rather than as the request finishing,
      # which is how it reads when the other end closes mid-stream. Expected, so
      # it is not logged and not an error.
      {:error, conn, %Mint.TransportError{reason: :closed}, _responses} ->
        {:stop, :normal, %{state | conn: conn}}

      # coveralls-ignore-start (a socket that fails in some way other than being
      # closed, which nothing on this side can bring about)
      {:error, conn, reason, _responses} ->
        Logger.warning("CDP stream error: #{inspect(reason)}")
        {:stop, {:cdp_stream_error, reason}, %{state | conn: conn}}

      # coveralls-ignore-stop

      :unknown ->
        {:noreply, state}
    end
  end

  # coveralls-ignore-start (a message arriving in the gap between starting and
  # connecting, which nothing on this side can time)
  def handle_info(_message, %__MODULE__{} = state), do: {:noreply, state}
  # coveralls-ignore-stop

  @impl true
  def terminate(_reason, %__MODULE__{conn: conn}) when conn != nil do
    Mint.HTTP.close(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # The session a command is addressed to rides at the top of the frame; everything
  # else the method takes goes under `params`. Chrome refuses a frame carrying any
  # other key, so the split is not cosmetic.
  defp command(id, method, params) do
    {session, params} = params |> Map.new() |> Map.pop_lazy(:session, fn -> nil end)
    frame = %{id: id, method: method, params: params}

    if session, do: Map.put(frame, :sessionId, session), else: frame
  end

  defp path(%URI{path: path, query: nil}), do: path
  defp path(%URI{path: path, query: query}), do: path <> "?" <> query

  # A websocket upgrade answers 101 and switches protocols, so Mint reports the
  # status and the headers and never a finished response. The upgrade is complete
  # when both have arrived, which can be in one message or two.
  defp await_upgrade(conn, ref, status \\ nil, headers \\ nil)

  defp await_upgrade(conn, ref, status, headers) when is_integer(status) and is_list(headers) do
    Mint.WebSocket.new(conn, ref, status, headers)
  end

  # Only the socket's own messages are taken out of the mailbox. A plain `receive`
  # here would swallow the first `GenServer.call` to arrive while the upgrade was
  # still in flight, and that caller would then wait for a reply to a command that
  # was never sent.
  # coveralls-ignore-start (the socket failing during the upgrade, and the
  # upgrade never answering: both need a server that accepts a connection and
  # then misbehaves at exactly that moment)
  defp await_upgrade(conn, ref, status, headers) do
    receive do
      {transport, _socket, _data} = message when transport in [:tcp, :ssl] ->
        stream_upgrade(conn, ref, status, headers, message)

      {transport, _socket} = message when transport in [:tcp_closed, :ssl_closed] ->
        stream_upgrade(conn, ref, status, headers, message)

      {transport, _socket, _reason} = message when transport in [:tcp_error, :ssl_error] ->
        stream_upgrade(conn, ref, status, headers, message)
    after
      10_000 -> {:error, :cdp_upgrade_timeout}
    end
  end

  # coveralls-ignore-stop

  defp stream_upgrade(conn, ref, status, headers, message) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        await_upgrade(
          conn,
          ref,
          status || find(responses, ref, :status),
          headers || find(responses, ref, :headers)
        )

      # coveralls-ignore-start (as above)
      {:error, _conn, reason, _responses} ->
        {:error, reason}

      :unknown ->
        await_upgrade(conn, ref, status, headers)
        # coveralls-ignore-stop
    end
  end

  defp find(responses, ref, kind) do
    Enum.find_value(responses, fn
      {^kind, ^ref, value} -> value
      _other -> nil
    end)
  end

  defp send_frame(%__MODULE__{conn: conn, websocket: websocket, ref: ref} = state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      {:ok, %{state | conn: conn, websocket: websocket}}
    else
      # coveralls-ignore-start (a frame the library refuses to encode, or a
      # socket that rejects a write without having closed)
      {:error, %Mint.WebSocket{} = websocket, reason} ->
        {:error, {reason, %{state | websocket: websocket}}}

      {:error, _conn, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  defp handle_response({:data, ref, data}, %__MODULE__{ref: ref} = state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        Enum.reduce(frames, %{state | websocket: websocket}, &handle_frame/2)

      # coveralls-ignore-start (a frame that is not a valid websocket frame,
      # which this side cannot make a server send)
      {:error, websocket, reason} ->
        Logger.warning("CDP decode error: #{inspect(reason)}")
        %{state | websocket: websocket}
        # coveralls-ignore-stop
    end
  end

  # coveralls-ignore-start (the stream reporting the request finishing rather
  # than erroring, which is the other shape a closed socket can arrive in)
  defp handle_response(_other, state), do: state

  defp closed?({:done, _ref}), do: true
  defp closed?({:error, _ref, _reason}), do: true
  # coveralls-ignore-stop

  defp closed?(_response), do: false

  defp handle_frame({:text, text}, %__MODULE__{} = state) do
    case Jason.decode(text) do
      {:ok, message} -> dispatch(message, state)
      {:error, _reason} -> state
    end
  end

  defp handle_frame({:close, _code, _reason}, %__MODULE__{} = state), do: state
  defp handle_frame(_frame, state), do: state

  # A reply carries the id of the command that asked for it; anything without one
  # is Chrome talking on its own.
  defp dispatch(%{"id" => id} = message, %__MODULE__{} = state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {from, pending} ->
        GenServer.reply(from, reply(message))
        %{state | pending: pending}
    end
  end

  defp dispatch(%{"method" => method} = message, %__MODULE__{} = state) do
    params = Map.get(message, "params", %{})
    for pid <- state.subscribers, do: send(pid, {:cdp_event, method, params})
    state
  end

  defp dispatch(_message, state), do: state

  defp reply(%{"error" => %{"message" => message}}), do: {:error, message}
  defp reply(%{"result" => result}), do: {:ok, result}
  defp reply(_message), do: {:ok, %{}}
end
