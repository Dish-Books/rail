defmodule Rail.Tools.Actions.TrustSandboxHostKeyTest do
  use Rail.DataCase, async: true

  alias Rail.Tools
  alias Rail.Tools.Schemas.SandboxHost

  # The reconnect that follows a trust is in host_connection_test.exs, against a real SSH server.
  setup do
    {:ok, host} = Tools.create_sandbox_host(system_scope(), %{name: "build-03", ssh_address: "rail@10.0.4.13:2222"})
    Repo.update_all(from(h in SandboxHost, where: h.id == ^host.id), set: [host_key_fingerprint: "SHA256:trusted"])
    # Stands in for the host's connection, which saw the host offer another key.
    {:ok, _owner} = Registry.register(Rail.Tools.HostRegistry, host.id, %{state: :unreachable, offered: "SHA256:offered"})
    %{host: host}
  end

  test "records the key the host offers now and says so, and a second press changes nothing", %{host: host} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "sandboxes")
    scope = user_scope(admin: true)

    assert {:ok, %SandboxHost{host_key_fingerprint: "SHA256:offered"} = trusted} =
             Tools.trust_sandbox_host_key(scope, host, "SHA256:offered")

    assert_receive :sandboxes_changed

    assert {:ok, ^trusted} = Tools.trust_sandbox_host_key(scope, host, "SHA256:offered")
  end

  test "refuses a key other than the one the host offers now", %{host: host} do
    assert {:error, :key_not_offered} = Tools.trust_sandbox_host_key(system_scope(), host, "SHA256:shown-earlier")
    assert %SandboxHost{host_key_fingerprint: "SHA256:trusted"} = Repo.get!(SandboxHost, host.id)
  end

  test "has nothing to trust on a host that never connected, which takes the first key it is offered" do
    {:ok, host} = Tools.create_sandbox_host(system_scope(), %{name: "build-05", ssh_address: "rail@10.0.4.15"})
    assert {:error, :key_not_offered} = Tools.trust_sandbox_host_key(system_scope(), host, "SHA256:offered")
  end

  test "is admin only", %{host: host} do
    assert {:error, :not_authorized} = Tools.trust_sandbox_host_key(user_scope(), host, "SHA256:offered")
  end
end
