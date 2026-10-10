defmodule Rail.SshDaemon do
  @moduledoc """
  An SSH server on loopback standing in for an extra host, which pipes an exec of
  `docker system dial-stdio` into a stand-in Docker that answers `/info`.
  """
  @behaviour :ssh_server_key_api
  @behaviour Plug

  @ed25519 {:namedCurve, {1, 3, 101, 112}}

  @doc """
  Starts the server, returning `%{daemon, port, fingerprint}`. Takes `authorized_keys`
  lines, a `host_key`, a fixed `port` to come back on, and `docker: false`.
  """
  def ssh_daemon(opts \\ []) do
    host_key = Keyword.get_lazy(opts, :host_key, &ssh_host_key/0)

    authorized =
      for line <- Keyword.get(opts, :authorized_keys, []),
          {key, _attrs} <- :ssh_file.decode(line, :openssh_key),
          do: key

    docker_port =
      if Keyword.get(opts, :docker, true) do
        {:ok, server} = Bandit.start_link(plug: __MODULE__, port: 0, startup_log: false, ip: :loopback)
        {:ok, {_address, port}} = ThousandIsland.listener_info(server)
        port
      end

    {:ok, daemon} =
      :ssh.daemon({127, 0, 0, 1}, Keyword.get(opts, :port, 0),
        key_cb: {__MODULE__, host_key: host_key, authorized: authorized},
        ssh_cli: {Rail.SshDaemonChannel, [docker_port]},
        auth_methods: ~c"publickey"
      )

    {:ok, info} = :ssh.daemon_info(daemon)
    {:ECPrivateKey, _version, _private, @ed25519, public, :asn1_NOVALUE} = host_key

    %{
      daemon: daemon,
      port: info[:port],
      fingerprint: to_string(:ssh.hostkey_fingerprint(:sha256, {{:ECPoint, public}, @ed25519}))
    }
  end

  @doc "Stops the server and every connection to it."
  def stop_ssh_daemon(%{daemon: daemon}), do: :ssh.stop_daemon(daemon)

  @doc "A new ed25519 host key."
  def ssh_host_key, do: :public_key.generate_key({:namedCurve, :ed25519})

  @impl :ssh_server_key_api
  def host_key(:"ssh-ed25519", options), do: {:ok, options[:key_cb_private][:host_key]}
  def host_key(_algorithm, _options), do: {:error, :not_ed25519}

  @impl :ssh_server_key_api
  def is_auth_key(key, _user, options), do: key in options[:key_cb_private][:authorized]

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, _options), do: Req.Test.json(conn, %{"NCPU" => 8, "MemTotal" => 34_359_738_368})
end
