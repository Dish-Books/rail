defmodule Rail.Tools.HostConnectionTest do
  # Connections run under the app's one host supervisor and write to the database from
  # their own process, so these share the sandbox and run alone.
  use Rail.DataCase, async: false
  use Oban.Testing, repo: Rail.Repo

  import Rail.SshDaemon

  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.HostConnection
  alias Rail.Tools.HostSupervisor
  alias Rail.Tools.Schemas.SandboxHost
  alias Rail.Tools.Workers.SyncSandboxImage

  setup {Req.Test, :set_req_test_to_shared}

  setup do
    on_exit(fn ->
      for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(HostSupervisor),
          do: DynamicSupervisor.terminate_child(HostSupervisor, pid)
    end)

    # Rail's image, and a host whose image matches unless a test says otherwise.
    Req.Test.stub(Docker, fn conn ->
      case {conn.host, conn.request_path} do
        {"127.0.0.1", "/info"} -> Req.Test.json(conn, %{"NCPU" => 16, "MemTotal" => 64 * 1024 ** 3})
        {_rail_or_host, "/images/rail-sandbox:latest/json"} -> Req.Test.json(conn, %{"Id" => "sha256:rail"})
      end
    end)

    {:ok, host} = Tools.create_sandbox_host(system_scope(), %{name: "build-02", ssh_address: "rail@127.0.0.1:1"})
    %{host: host}
  end

  test "the first connection signs in with the generated key, records the host key, and reaches Docker through the bridge",
       %{host: host} do
    %{fingerprint: fingerprint} = daemon = ssh_daemon(authorized_keys: [host.public_key])
    host = %{host | ssh_address: "rail@127.0.0.1:#{daemon.port}"}
    Phoenix.PubSub.subscribe(Rail.PubSub, "sandboxes")

    {:ok, pid} = DynamicSupervisor.start_child(HostSupervisor, {HostConnection, host})
    _settled = :sys.get_state(pid)

    assert %SandboxHost{host_key_fingerprint: ^fingerprint} = Repo.get!(SandboxHost, host.id)

    assert %{
             state: :connected,
             since: %DateTime{},
             trusted: ^fingerprint,
             offered: ^fingerprint,
             machine: %{cpus: 16, memory_gb: 64},
             image: :current
           } = HostConnection.status(host.id)

    assert_receive :sandboxes_changed
    refute_enqueued(worker: SyncSandboxImage)

    {:ok, port} = HostConnection.docker_port(host.id)
    # A client that hangs up first closes its channel on the host.
    {:ok, early} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.close(early)

    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "GET /info HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n")
    {:ok, response} = :gen_tcp.recv(socket, 0, 5_000)
    assert response =~ "HTTP/1.1 200"
    assert response =~ ~s("NCPU":8)
  end

  test "a host that answers on no Docker closes each request at once", %{host: host} do
    daemon = ssh_daemon(authorized_keys: [host.public_key], docker: false)
    host = %{host | ssh_address: "rail@127.0.0.1:#{daemon.port}"}
    {:ok, pid} = DynamicSupervisor.start_child(HostSupervisor, {HostConnection, host})
    _settled = :sys.get_state(pid)

    {:ok, port} = HostConnection.docker_port(host.id)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
  end

  test "a changed host key is refused and reported until an admin trusts it, and then Rail reconnects",
       %{host: host} do
    %{fingerprint: trusted} = daemon = ssh_daemon(authorized_keys: [host.public_key])
    {:ok, host} = Tools.update_sandbox_host(system_scope(), host, %{ssh_address: "rail@127.0.0.1:#{daemon.port}"})
    {:ok, pid} = DynamicSupervisor.start_child(HostSupervisor, {HostConnection, host})
    _settled = :sys.get_state(pid)
    Phoenix.PubSub.subscribe(Rail.PubSub, "sandboxes")

    stop_ssh_daemon(daemon)
    %{fingerprint: offered} = ssh_daemon(authorized_keys: [host.public_key], port: daemon.port)
    assert_receive :sandboxes_changed
    send(pid, :connect)
    _settled = :sys.get_state(pid)

    assert %{state: :unreachable, since: %DateTime{}, error: :host_key_changed, offered: ^offered, trusted: ^trusted} =
             HostConnection.status(host.id)

    assert {:error, :host_unreachable} = HostConnection.docker_port(host.id)
    assert {:error, :host_unreachable} = Docker.info(host.id)

    stub(Rail, :sandbox_runtime, fn -> :docker end)
    host = Repo.get!(SandboxHost, host.id)

    assert {:ok, %SandboxHost{host_key_fingerprint: ^offered}} =
             Tools.trust_sandbox_host_key(system_scope(), host, offered)

    [{_id, reconnected, _type, _modules}] = DynamicSupervisor.which_children(HostSupervisor)
    refute reconnected == pid
    _settled = :sys.get_state(reconnected)
    assert %{state: :connected, trusted: ^offered} = HostConnection.status(host.id)
  end

  test "a key the host refuses reads as permission denied", %{host: host} do
    daemon = ssh_daemon(authorized_keys: [])
    host = %{host | ssh_address: "rail@127.0.0.1:#{daemon.port}"}
    {:ok, pid} = DynamicSupervisor.start_child(HostSupervisor, {HostConnection, host})
    _settled = :sys.get_state(pid)

    assert %{state: :unreachable, error: :permission_denied} = HostConnection.status(host.id)
    assert %SandboxHost{host_key_fingerprint: nil} = Repo.get!(SandboxHost, host.id)
  end

  test "a closed port reads as refused, and a second failure keeps the time it went down", %{host: host} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "sandboxes")
    {:ok, pid} = DynamicSupervisor.start_child(HostSupervisor, {HostConnection, host})
    _settled = :sys.get_state(pid)
    assert %{state: :unreachable, since: since, error: :econnrefused} = HostConnection.status(host.id)
    assert_receive :sandboxes_changed

    send(pid, :connect)
    _settled = :sys.get_state(pid)
    assert %{state: :unreachable, since: ^since} = HostConnection.status(host.id)
    refute_receive :sandboxes_changed
  end

  test "a host that drops reads unreachable, and the connection comes back when the host does", %{host: host} do
    host_key = ssh_host_key()
    daemon = ssh_daemon(authorized_keys: [host.public_key], host_key: host_key)
    host = %{host | ssh_address: "rail@127.0.0.1:#{daemon.port}"}
    {:ok, pid} = DynamicSupervisor.start_child(HostSupervisor, {HostConnection, host})
    _settled = :sys.get_state(pid)
    Phoenix.PubSub.subscribe(Rail.PubSub, "sandboxes")

    stop_ssh_daemon(daemon)
    assert_receive :sandboxes_changed
    assert %{state: :unreachable, since: %DateTime{}, error: :connection_lost} = HostConnection.status(host.id)

    _back = ssh_daemon(authorized_keys: [host.public_key], host_key: host_key, port: daemon.port)
    send(pid, :connect)
    _settled = :sys.get_state(pid)
    assert %{state: :connected, error: nil} = HostConnection.status(host.id)
    assert_receive :sandboxes_changed
  end

  test "a ping finds a live connection alive, and a bridge that dies counts as a dropped connection", %{host: host} do
    daemon = ssh_daemon(authorized_keys: [host.public_key])
    host = %{host | ssh_address: "rail@127.0.0.1:#{daemon.port}"}
    {:ok, pid} = DynamicSupervisor.start_child(HostSupervisor, {HostConnection, host})

    send(pid, :ping)
    send(pid, :connect)
    %{bridge: bridge} = :sys.get_state(pid)
    assert %{state: :connected, port: port} = HostConnection.status(host.id)
    assert {:ok, ^port} = HostConnection.docker_port(host.id)

    Phoenix.PubSub.subscribe(Rail.PubSub, "sandboxes")
    Process.exit(bridge, :kill)
    assert_receive :sandboxes_changed
    send(pid, :ping)
    _settled = :sys.get_state(pid)
    assert %{state: :unreachable, error: :connection_lost} = HostConnection.status(host.id)
  end

  test "a host whose image is not Rail's gets a copy queued, and its progress is broadcast about once a second",
       %{host: host} do
    Req.Test.stub(Docker, fn conn ->
      case {conn.host, conn.request_path} do
        {"127.0.0.1", "/info"} -> Req.Test.json(conn, %{"NCPU" => 16, "MemTotal" => 64 * 1024 ** 3})
        {"127.0.0.1", "/images/rail-sandbox:latest/json"} -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
        {"docker", "/images/rail-sandbox:latest/json"} -> Req.Test.json(conn, %{"Id" => "sha256:rail"})
      end
    end)

    daemon = ssh_daemon(authorized_keys: [host.public_key])
    host = %{host | ssh_address: "rail@127.0.0.1:#{daemon.port}"}
    Phoenix.PubSub.subscribe(Rail.PubSub, "sandboxes")
    {:ok, pid} = DynamicSupervisor.start_child(HostSupervisor, {HostConnection, host})
    _settled = :sys.get_state(pid)

    assert %{image: {:copying, 0, nil}} = HostConnection.status(host.id)
    assert_enqueued(worker: SyncSandboxImage, args: %{host_id: host.id})
    assert_receive :sandboxes_changed
    assert_receive :sandboxes_changed

    HostConnection.report_image(host.id, {:copying, 100, 1_000})
    HostConnection.report_image(host.id, {:copying, 200, 1_000})
    _settled = :sys.get_state(pid)
    assert %{image: {:copying, 200, 1_000}} = HostConnection.status(host.id)
    assert_receive :sandboxes_changed
    refute_receive :sandboxes_changed

    HostConnection.report_image(host.id, :current)
    assert_receive :sandboxes_changed
  end

  test "a host Docker cannot read for it stays connected with no figures and no image", %{host: host} do
    Req.Test.stub(Docker, fn conn -> conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "busy"}) end)
    daemon = ssh_daemon(authorized_keys: [host.public_key])
    host = %{host | ssh_address: "rail@127.0.0.1:#{daemon.port}"}
    {:ok, pid} = DynamicSupervisor.start_child(HostSupervisor, {HostConnection, host})
    _settled = :sys.get_state(pid)

    assert %{state: :connected, machine: nil, image: nil} = HostConnection.status(host.id)
    refute_enqueued(worker: SyncSandboxImage)
  end

  test "something that answers on the port but speaks no SSH reads as SSH's own words", %{host: host} do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(listener)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      :gen_tcp.send(socket, "SSH-1.0-OpenSSH_2.0\r\n")
      :gen_tcp.recv(socket, 0, 5_000)
    end)

    host = %{host | ssh_address: "rail@127.0.0.1:#{port}"}
    {:ok, pid} = DynamicSupervisor.start_child(HostSupervisor, {HostConnection, host})
    _settled = :sys.get_state(pid)

    assert %{state: :unreachable, error: "" <> _words} = HostConnection.status(host.id)
  end
end
