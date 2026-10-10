defmodule Rail.Tools.DockerBridge do
  @moduledoc """
  Pipes each connection to a loopback port of Rail's machine into `docker system
  dial-stdio` over a host's SSH connection, as the Docker CLI does for `ssh://` hosts.
  """
  use ThousandIsland.Handler

  @timeout 10_000

  @impl ThousandIsland.Handler
  def handle_connection(_socket, %{conn: conn} = state) do
    with {:ok, channel} <- :ssh_connection.session_channel(conn, @timeout),
         :success <- :ssh_connection.exec(conn, channel, ~c"docker system dial-stdio", @timeout) do
      {:continue, Map.put(state, :channel, channel)}
    else
      _refused -> {:close, state}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, _socket, %{conn: conn, channel: channel} = state) do
    # A channel that refuses the bytes has closed, and its closed message ends this connection.
    _sent_or_closed = :ssh_connection.send(conn, channel, data, @timeout)
    {:continue, state}
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, %{conn: conn, channel: channel}), do: :ssh_connection.close(conn, channel)
  def handle_close(_socket, _state), do: :ok

  def handle_info({:ssh_cm, conn, {:data, channel, type, data}}, {socket, %{conn: conn, channel: channel} = state}) do
    :ssh_connection.adjust_window(conn, channel, byte_size(data))
    # Type 1 is the command's stderr, which is Docker's and not the client's to read.
    if type == 0, do: ThousandIsland.Socket.send(socket, data)
    {:noreply, {socket, state}}
  end

  def handle_info({:ssh_cm, conn, {ended, channel}}, {socket, %{conn: conn, channel: channel} = state})
      when ended in [:eof, :closed] do
    {:stop, :normal, {socket, state}}
  end

  def handle_info({:ssh_cm, _conn, _exit_status_or_signal}, {socket, state}), do: {:noreply, {socket, state}}
end
