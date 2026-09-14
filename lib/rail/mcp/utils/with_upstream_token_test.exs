defmodule Rail.Mcp.Utils.WithUpstreamTokenTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.WithUpstreamToken

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.McpConnection
  alias Rail.Mcp.Schemas.McpServer
  alias Rail.Users

  setup do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "wut_gh_#{id}", login: "wut_#{id}", email: "wut_#{id}@example.com"})

    {:ok, server} =
      Mcp.create_server(system_scope(), %{
        name: "upstream_#{id}",
        url: "https://mcp.example.com/mcp",
        token_endpoint: "https://auth.example.com/token",
        client_id: "client_1"
      })

    %{user: user, server: server}
  end

  test "passes the token through and returns what the call returns" do
    assert {:ok, :done} = with_upstream_token(nil, %McpServer{auth: :none}, fn nil -> {:ok, :done} end)
  end

  test "refreshes and retries once when the server rejects the token", %{user: user, server: server} do
    Repo.insert!(%McpConnection{
      user_id: user.id,
      mcp_server_id: server.id,
      access_token: "at_old",
      refresh_token: "rt_1",
      expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
    })

    Req.Test.expect(Mcp, &Req.Test.json(&1, %{"access_token" => "at_new"}))

    assert {:ok, "at_new"} =
             with_upstream_token(user, server, fn
               "at_old" -> {:error, :unauthorized}
               token -> {:ok, token}
             end)
  end

  test "returns the token error when there is none to use or refresh", %{user: user, server: server} do
    assert {:error, :not_connected} = with_upstream_token(user, server, fn _token -> flunk("never called") end)

    Repo.insert!(%McpConnection{user_id: user.id, mcp_server_id: server.id, access_token: "at_old"})

    assert {:error, :token_expired} = with_upstream_token(user, server, fn _token -> {:error, :unauthorized} end)
  end
end
