defmodule Rail.Mcp.Actions.DeleteServerTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp

  test "deletes a server" do
    {:ok, %{id: server_id} = server} =
      Mcp.create_server(system_scope(), %{name: "des_linear", url: "https://mcp.linear.app/mcp"})

    assert {:ok, _deleted} = Mcp.delete_server(system_scope(), server)
    assert {:error, :not_found} = Mcp.get_server(id: server_id)
  end
end
