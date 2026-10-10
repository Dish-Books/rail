defmodule Rail.Tools.Actions.UpdateSandboxHostTest do
  use Rail.DataCase, async: true

  alias Rail.Tools
  alias Rail.Tools.Schemas.SandboxHost

  setup do
    {:ok, host} = Tools.create_sandbox_host(system_scope(), %{name: "build-02", ssh_address: "rail@10.0.4.12"})
    %{host: host}
  end

  test "saves an admin's edit and says so", %{host: host} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "sandboxes")

    assert {:ok, %SandboxHost{name: "build-03", ssh_address: "rail@10.0.4.13:2222"}} =
             Tools.update_sandbox_host(user_scope(admin: true), host, %{
               name: "build-03",
               ssh_address: "rail@10.0.4.13:2222"
             })

    assert_receive :sandboxes_changed
  end

  test "refuses a bad address", %{host: host} do
    assert {:error, changeset} = Tools.update_sandbox_host(system_scope(), host, %{ssh_address: "10.0.4.13"})
    assert %{ssh_address: [_message]} = errors_on(changeset)
  end

  test "is admin only", %{host: host} do
    assert {:error, :not_authorized} = Tools.update_sandbox_host(user_scope(), host, %{name: "build-03"})
  end
end
