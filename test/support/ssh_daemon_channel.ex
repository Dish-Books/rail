defmodule Rail.SshDaemonChannel do
  @moduledoc """
  Pipes `Rail.SshDaemon`'s `docker system dial-stdio` to the stand-in Docker both
  ways, with a line on stderr. Any other command, or no Docker, is refused.
  """
  @behaviour :ssh_server_channel

  @impl true
  def init([docker_port]), do: {:ok, %{docker_port: docker_port, conn: nil, channel: nil, socket: nil}}

  @impl true
  def handle_msg({:ssh_channel_up, channel, conn}, state), do: {:ok, %{state | channel: channel, conn: conn}}

  def handle_msg({:tcp, _socket, data}, %{conn: conn, channel: channel} = state) do
    :ok = :ssh_connection.send(conn, channel, data)
    {:ok, state}
  end

  def handle_msg({:tcp_closed, _socket}, %{conn: conn, channel: channel} = state) do
    :ssh_connection.exit_status(conn, channel, 0)
    :ssh_connection.send_eof(conn, channel)
    {:stop, channel, state}
  end

  @impl true
  def handle_ssh_msg(
        {:ssh_cm, conn, {:exec, channel, want_reply, ~c"docker system dial-stdio"}},
        %{docker_port: port} = state
      )
      when is_integer(port) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: true])
    :ssh_connection.reply_request(conn, want_reply, :success, channel)
    :ssh_connection.send(conn, channel, 1, "dial-stdio: connected\n")
    {:ok, %{state | socket: socket}}
  end

  def handle_ssh_msg({:ssh_cm, conn, {:exec, channel, want_reply, _command}}, state) do
    :ssh_connection.reply_request(conn, want_reply, :failure, channel)
    {:stop, channel, state}
  end

  def handle_ssh_msg({:ssh_cm, conn, {:data, channel, 0, data}}, %{socket: socket} = state) do
    :ssh_connection.adjust_window(conn, channel, byte_size(data))
    :ok = :gen_tcp.send(socket, data)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _conn, {:closed, channel}}, state), do: {:stop, channel, state}
  def handle_ssh_msg({:ssh_cm, _conn, _eof_or_request}, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{socket: socket}) when is_port(socket), do: :gen_tcp.close(socket)
  def terminate(_reason, _state), do: :ok
end
