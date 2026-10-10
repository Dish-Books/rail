defmodule Rail.Tools.Utils.EnsureHostConnectionsTest do
  use Rail.DataCase, async: true

  import Rail.Tools.Utils.EnsureHostConnections

  alias Rail.Tools
  alias Rail.Tools.HostConnection
  alias Rail.Tools.HostRegistry

  # Each host points at a closed port, so its connection never reaches the database.
  setup do
    scope = system_scope()
    {:ok, first} = Tools.create_sandbox_host(scope, %{name: "build-02", ssh_address: "rail@127.0.0.1:1"})
    {:ok, second} = Tools.create_sandbox_host(scope, %{name: "build-03", ssh_address: "rail@127.0.0.1:1"})

    on_exit(fn ->
      for host <- [first, second],
          [{pid, _status}] <- [Registry.lookup(HostRegistry, host.id)],
          do: DynamicSupervisor.terminate_child(Rail.Tools.HostSupervisor, pid)
    end)

    %{scope: scope, first: first, second: second}
  end

  test "under the local runtime starts no connection", %{first: first} do
    assert [] = ensure_host_connections()
    assert HostConnection.status(first.id) == nil
  end

  test "under Docker runs one connection per host, keeps it, and restarts it for a new address",
       %{scope: scope, first: first, second: second} do
    stub(Rail, :sandbox_runtime, fn -> :docker end)

    assert [{:ok, first_pid}, {:ok, second_pid}] = ensure_host_connections()
    assert [{:ok, ^first_pid}, {:ok, ^second_pid}] = ensure_host_connections()
    assert %{address: "rail@127.0.0.1:1"} = HostConnection.status(first.id)

    {:ok, _moved} = Tools.update_sandbox_host(scope, first, %{ssh_address: "rail@127.0.0.1:2"})
    assert [{:ok, moved_pid}, {:ok, ^second_pid}] = ensure_host_connections()
    refute moved_pid == first_pid
    refute Process.alive?(first_pid)
    assert %{address: "rail@127.0.0.1:2"} = HostConnection.status(first.id)

    assert [{:ok, ^moved_pid}, {:ok, ^second_pid}] = ensure_host_connections()
    assert second.id != first.id
  end

  test "under Docker stops a removed host's connection", %{scope: scope, second: second} do
    stub(Rail, :sandbox_runtime, fn -> :docker end)
    [{:ok, _first_pid}, {:ok, second_pid}] = ensure_host_connections()

    {:ok, _removed} = Tools.remove_sandbox_host(scope, second)

    refute Process.alive?(second_pid)
    assert HostConnection.status(second.id) == nil
  end

  test "under Docker keeps a connection another reconcile started first", %{first: first} do
    stub(Rail, :sandbox_runtime, fn -> :docker end)
    {:ok, _owner} = Registry.register(HostRegistry, first.id, %{address: first.ssh_address, trusted: nil})
    test_pid = self()

    assert [{:ok, ^test_pid}, {:ok, _second_pid}] = ensure_host_connections()
  end
end
