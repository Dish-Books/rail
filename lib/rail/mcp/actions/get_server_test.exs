defmodule Rail.Mcp.Actions.GetServerTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.McpServer

  test "finds a server, or says it is not there" do
    {:ok, %{id: server_id}} =
      Mcp.create_server(system_scope(), %{name: "gs_linear", url: "https://mcp.linear.app/mcp"})

    assert {:ok, %McpServer{id: ^server_id}} = Mcp.get_server(name: "gs_linear")
    assert {:error, :not_found} = Mcp.get_server(name: "missing")
  end
end
