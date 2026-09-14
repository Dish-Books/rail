defmodule Rail.Mcp.Actions.ListConnectionsTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.McpConnection
  alias Rail.Scope
  alias Rail.Users

  test "lists the scope's user's connections, and none without a user" do
    id = System.unique_integer([:positive])

    {:ok, %{id: user_id} = user} =
      Users.register_oauth_user(%{github_id: "lc_gh_#{id}", login: "lc_#{id}", email: "lc_#{id}@example.com"})

    {:ok, %{id: server_id}} =
      Mcp.create_server(system_scope(), %{name: "lc_linear", url: "https://mcp.example.com/mcp"})

    Repo.insert!(%McpConnection{user_id: user_id, mcp_server_id: server_id, access_token: "at_1"})

    assert [%McpConnection{mcp_server_id: ^server_id}] = Mcp.list_connections(Scope.for_user(user))
    assert [] = Mcp.list_connections(system_scope())
  end
end
