defmodule Rail.Tools.Actions.ListSandboxHostsTest do
  use Rail.DataCase, async: true

  alias Rail.Tools
  alias Rail.Tools.Schemas.SandboxHost

  test "lists hosts oldest first, the id breaking a tie, leaving out removed ones" do
    scope = system_scope()
    {:ok, first} = Tools.create_sandbox_host(scope, %{name: "build-02", ssh_address: "rail@10.0.4.12"})
    {:ok, gone} = Tools.create_sandbox_host(scope, %{name: "build-03", ssh_address: "rail@10.0.4.13"})
    {:ok, last} = Tools.create_sandbox_host(scope, %{name: "build-04", ssh_address: "rail@10.0.4.14"})
    {:ok, _removed} = Tools.remove_sandbox_host(scope, gone)

    # The same moment for both, so only the id can order them.
    Repo.update_all(from(h in SandboxHost, where: h.id in ^[first.id, last.id]), set: [inserted_at: first.inserted_at])
    [first_id, last_id] = Enum.sort([first.id, last.id])

    assert [%SandboxHost{id: ^first_id}, %SandboxHost{id: ^last_id}] = Tools.list_sandbox_hosts()
  end
end
