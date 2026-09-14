defmodule Rail.Mcp.Actions.ListServersTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.McpServer

  test "lists servers by name" do
    {:ok, _server} =
      Mcp.create_server(system_scope(), %{name: "ls_sentry", url: "https://mcp.sentry.dev/mcp"})

    {:ok, _server} =
      Mcp.create_server(system_scope(), %{name: "ls_linear", url: "https://mcp.linear.app/mcp"})

    assert [%McpServer{name: "ls_linear"}, %McpServer{name: "ls_sentry"}] = Mcp.list_servers()
  end
end
