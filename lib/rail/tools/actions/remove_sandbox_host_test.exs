defmodule Rail.Tools.Actions.RemoveSandboxHostTest do
  use Rail.DataCase, async: true

  alias Rail.Tools
  alias Rail.Tools.Schemas.SandboxHost

  setup do
    {:ok, host} = Tools.create_sandbox_host(system_scope(), %{name: "build-02", ssh_address: "rail@10.0.4.12"})
    %{host: host}
  end

  test "stamps the host removed, takes it off the list and says so, and a second removal changes nothing",
       %{host: host} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "sandboxes")
    scope = user_scope(admin: true)

    assert {:ok, %SandboxHost{removed_at: %DateTime{} = removed_at}} = Tools.remove_sandbox_host(scope, host)
    assert Tools.list_sandbox_hosts() == []
    assert_receive :sandboxes_changed

    assert {:ok, %SandboxHost{removed_at: ^removed_at}} = Tools.remove_sandbox_host(scope, host)
  end

  test "is admin only", %{host: host} do
    assert {:error, :not_authorized} = Tools.remove_sandbox_host(user_scope(), host)
    assert [%SandboxHost{removed_at: nil}] = Tools.list_sandbox_hosts()
  end
end
