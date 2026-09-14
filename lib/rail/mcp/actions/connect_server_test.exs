defmodule Rail.Mcp.Actions.ConnectServerTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.McpConnection
  alias Rail.Scope
  alias Rail.Users

  setup do
    id = System.unique_integer([:positive])

    {:ok, %{id: user_id} = user} =
      Users.register_oauth_user(%{github_id: "cs_gh_#{id}", login: "cs_#{id}", email: "cs_#{id}@example.com"})

    {:ok, %{id: server_id} = server} =
      Mcp.create_server(system_scope(), %{
        name: "linear_#{id}",
        url: "https://mcp.example.com/mcp",
        token_endpoint: "https://auth.example.com/token",
        client_id: "client_1"
      })

    %{scope: Scope.for_user(user), user_id: user_id, server: server, server_id: server_id}
  end

  test "stores the user's tokens, replacing an earlier connection", %{
    scope: scope,
    server: server,
    user_id: user_id,
    server_id: server_id
  } do
    Req.Test.expect(Mcp, fn conn ->
      assert %{"code" => "code_1", "code_verifier" => "verifier_1"} = conn |> Req.Test.raw_body() |> URI.decode_query()

      Req.Test.json(conn, %{
        "access_token" => "at_1",
        "refresh_token" => "rt_1",
        "expires_in" => 3600,
        "scope" => ["read", "write"]
      })
    end)

    assert {:ok, %McpConnection{user_id: ^user_id, mcp_server_id: ^server_id, access_token: "at_1", scope: "read write"}} =
             Mcp.connect_server(scope, server, "code_1", "verifier_1")

    Req.Test.expect(Mcp, &Req.Test.json(&1, %{"access_token" => "at_2", "scope" => "read"}))

    assert {:ok, %McpConnection{access_token: "at_2", refresh_token: nil, expires_at: nil, scope: "read"}} =
             Mcp.connect_server(scope, server, "code_2", "verifier_2")

    assert [%McpConnection{access_token: "at_2"}] = Mcp.list_connections(scope)

    Req.Test.expect(Mcp, &Req.Test.json(&1, %{"access_token" => "at_3"}))

    assert {:ok, %McpConnection{access_token: "at_3", scope: nil}} =
             Mcp.connect_server(scope, server, "code_3", "verifier_3")
  end

  test "returns a failed exchange", %{scope: scope, server: server} do
    Req.Test.expect(Mcp, &(&1 |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})))

    assert {:error, {:mcp_oauth_error, 400, _body}} = Mcp.connect_server(scope, server, "bad", "verifier")
  end

  test "needs a signed-in user", %{server: server} do
    assert {:error, :not_authenticated} = Mcp.connect_server(system_scope(), server, "code", "verifier")
  end
end
