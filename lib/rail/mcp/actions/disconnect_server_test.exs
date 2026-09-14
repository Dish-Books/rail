defmodule Rail.Mcp.Actions.DisconnectServerTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.McpConnection
  alias Rail.Scope
  alias Rail.Users

  test "removes only the scope's user's connection" do
    id = System.unique_integer([:positive])

    {:ok, user} = Users.register_oauth_user(%{github_id: "ds_gh_#{id}", login: "ds_#{id}", email: "ds_#{id}@example.com"})

    {:ok, other} =
      Users.register_oauth_user(%{github_id: "ds2_gh_#{id}", login: "ds2_#{id}", email: "ds2_#{id}@example.com"})

    {:ok, server} =
      Mcp.create_server(system_scope(), %{name: "dcs_linear", url: "https://mcp.example.com/mcp"})

    Repo.insert!(%McpConnection{user_id: user.id, mcp_server_id: server.id, access_token: "at_user"})
    Repo.insert!(%McpConnection{user_id: other.id, mcp_server_id: server.id, access_token: "at_other"})

    assert :ok = Mcp.disconnect_server(Scope.for_user(user), server)
    assert [] = Mcp.list_connections(Scope.for_user(user))
    assert [%McpConnection{access_token: "at_other"}] = Mcp.list_connections(Scope.for_user(other))
    assert {:error, :not_authenticated} = Mcp.disconnect_server(system_scope(), server)
  end
end
