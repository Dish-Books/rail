defmodule Rail.Mcp.Actions.UpdateServerTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.McpServer

  test "updates a server" do
    {:ok, server} =
      Mcp.create_server(system_scope(), %{name: "us_linear", url: "https://mcp.linear.app/mcp"})

    assert {:ok, %McpServer{enabled: false}} = Mcp.update_server(system_scope(), server, %{enabled: false})
  end
end
