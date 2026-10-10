defmodule Rail.Tools.HostConnection do
  @moduledoc """
  Holds one host's SSH connection and Docker bridge, keeping what it knows in
  `Rail.Tools.HostRegistry` so reading it never waits on a connection attempt.
  """
  use GenServer

  import Ecto.Query
  import Rail.Tools.Utils.ReadSandboxHost

  alias Rail.Repo
  alias Rail.Tools.DockerBridge
  alias Rail.Tools.HostKeys
  alias Rail.Tools.Schemas.SandboxHost
  alias Rail.Tools.Workers.SyncSandboxImage

  @registry Rail.Tools.HostRegistry
  @timeout 10_000
  @first_retry_ms 5_000
  @last_retry_ms 60_000
  # Without a keepalive in Erlang's SSH, a host that vanishes is only noticed when asked.
  @ping_ms 30_000
  @progress_ms 1_000

  def start_link(%SandboxHost{} = host) do
    status = %{
      address: host.ssh_address,
      trusted: host.host_key_fingerprint,
      state: :connecting,
      since: DateTime.utc_now(),
      error: nil,
      offered: nil,
      port: nil,
      machine: nil,
      image: nil
    }

    GenServer.start_link(__MODULE__, host, name: {:via, Registry, {@registry, host.id, status}})
  end

  @doc "The loopback port that reaches host `host_id`'s Docker, while it is connected."
  def docker_port(host_id) do
    case Registry.lookup(@registry, host_id) do
      [{_pid, %{state: :connected, port: port}}] -> {:ok, port}
      _down_or_not_started -> {:error, :host_unreachable}
    end
  end

  @doc "What the connection knows of host `host_id`, or nil when none is running."
  def status(host_id) do
    case Registry.lookup(@registry, host_id) do
      [{_pid, status}] -> status
      [] -> nil
    end
  end

  @doc "Records where the copy of Rail's sandbox image to host `host_id` stands."
  def report_image(host_id, image_state) do
    GenServer.cast({:via, Registry, {@registry, host_id}}, {:image, image_state})
  end

  @impl true
  def init(host) do
    Process.flag(:trap_exit, true)
    {:ok, %{host: host, conn: nil, bridge: nil, retry_ms: @first_retry_ms, progress_at: nil}, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: connect(state)

  def handle_continue(:check_image, %{host: host} = state) do
    {machine, image} =
      case read_sandbox_host(host) do
        {:ok, %{image: :current} = read} ->
          {Map.take(read, [:cpus, :memory_gb]), :current}

        {:ok, %{image: :differs} = read} ->
          {:ok, _job} = %{host_id: host.id} |> SyncSandboxImage.new() |> Oban.insert()
          {Map.take(read, [:cpus, :memory_gb]), {:copying, 0, nil}}

        {:error, _unreadable} ->
          {nil, nil}
      end

    {:noreply, update_status(state, &%{&1 | machine: machine, image: image})}
  end

  @impl true
  def handle_cast({:image, image}, state) do
    now = System.monotonic_time(:millisecond)
    previous = status(state.host.id).image

    # Progress moves every chunk; the page only needs it about once a second.
    if match?({:copying, _sent, _total}, image) and match?({:copying, _sent, _total}, previous) and
         is_integer(state.progress_at) and now - state.progress_at < @progress_ms do
      {:noreply, update_status(state, &%{&1 | image: image}, broadcast: false)}
    else
      {:noreply, update_status(%{state | progress_at: now}, &%{&1 | image: image})}
    end
  end

  @impl true
  def handle_info(:connect, %{conn: nil} = state), do: connect(state)
  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info(:ping, %{conn: conn} = state) when is_pid(conn) do
    case :ssh_connection.session_channel(conn, @timeout) do
      {:ok, channel} -> :ssh_connection.close(conn, channel)
      # coveralls-ignore-next-line (needs a host that stops answering without closing the connection)
      {:error, _timeout_or_closed} -> :ssh.close(conn)
    end

    Process.send_after(self(), :ping, @ping_ms)
    {:noreply, state}
  end

  def handle_info(:ping, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, conn, _reason}, %{conn: conn} = state), do: lost(%{state | conn: nil})
  def handle_info({:EXIT, bridge, _reason}, %{bridge: bridge} = state), do: lost(%{state | bridge: nil})

  # A rekey asks for the host key again, and the links Erlang's SSH makes exit with the connection.
  def handle_info(_stray, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{conn: conn}) when is_pid(conn), do: :ssh.close(conn)
  def terminate(_reason, _state), do: :ok

  defp connect(%{host: host} = state) do
    {user, address, port} = SandboxHost.ssh_target(host)
    [{key, _comment} | _public] = :ssh_file.decode(host.private_key, :openssh_key_v1)

    options = [
      user: String.to_charlist(user),
      key_cb: {HostKeys, key: key, trusted: host.host_key_fingerprint, notify: self()},
      auth_methods: ~c"publickey",
      user_interaction: false,
      save_accepted_host: false,
      quiet_mode: true,
      connect_timeout: @timeout,
      # The setup docs check the ed25519 host key, so that is the one asked for first.
      modify_algorithms: [prepend: [public_key: [:"ssh-ed25519"]]]
    ]

    result = :ssh.connect(String.to_charlist(address), port, options, @timeout)
    # HostKeys sent it from inside the handshake, so it is already here when connect returns.
    offered =
      receive do
        {:host_key_offered, fingerprint} -> fingerprint
      after
        0 -> nil
      end

    case result do
      {:ok, conn} ->
        Process.monitor(conn)
        host = record_host_key(host, offered)

        {:ok, bridge} =
          ThousandIsland.start_link(
            port: 0,
            transport_options: [ip: {127, 0, 0, 1}],
            handler_module: DockerBridge,
            handler_options: %{conn: conn},
            read_timeout: :infinity
          )

        {:ok, {_ip, bridge_port}} = ThousandIsland.listener_info(bridge)
        Process.send_after(self(), :ping, @ping_ms)

        state =
          update_status(
            %{state | host: host, conn: conn, bridge: bridge, retry_ms: @first_retry_ms},
            &%{
              &1
              | trusted: host.host_key_fingerprint,
                state: :connected,
                since: DateTime.utc_now(),
                error: nil,
                offered: offered,
                port: bridge_port
            }
          )

        {:noreply, state, {:continue, :check_image}}

      {:error, reason} ->
        error =
          cond do
            is_binary(host.host_key_fingerprint) and is_binary(offered) and offered != host.host_key_fingerprint ->
              :host_key_changed

            reason == ~c"Unable to connect using the available authentication methods" ->
              :permission_denied

            is_atom(reason) ->
              reason

            true ->
              to_string(reason)
          end

        {:noreply, unreachable(state, error, offered)}
    end
  end

  defp lost(%{conn: conn, bridge: bridge} = state) do
    if is_pid(bridge), do: ThousandIsland.stop(bridge)
    if is_pid(conn), do: :ssh.close(conn)
    {:noreply, unreachable(%{state | conn: nil, bridge: nil}, :connection_lost, status(state.host.id).offered)}
  end

  defp unreachable(state, error, offered) do
    Process.send_after(self(), :connect, state.retry_ms)

    state
    |> Map.put(:retry_ms, min(state.retry_ms * 2, @last_retry_ms))
    |> update_status(fn status ->
      since = if status.state == :unreachable, do: status.since, else: DateTime.utc_now()
      %{status | state: :unreachable, since: since, error: error, offered: offered, port: nil}
    end)
  end

  # Only while none is recorded, so a key an admin trusted meanwhile is never overwritten.
  defp record_host_key(%SandboxHost{host_key_fingerprint: nil} = host, "" <> offered) do
    {_recorded, _rows} =
      Repo.update_all(
        from(h in SandboxHost, where: h.id == ^host.id and is_nil(h.host_key_fingerprint)),
        set: [host_key_fingerprint: offered, updated_at: DateTime.utc_now()]
      )

    %{host | host_key_fingerprint: offered}
  end

  defp record_host_key(host, _offered), do: host

  defp update_status(state, fun, opts \\ []) do
    {new, old} = Registry.update_value(@registry, state.host.id, fun)

    if new != old and Keyword.get(opts, :broadcast, true),
      do: Phoenix.PubSub.broadcast(Rail.PubSub, "sandboxes", :sandboxes_changed)

    state
  end
end
