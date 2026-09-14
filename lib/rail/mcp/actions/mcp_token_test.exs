defmodule Rail.Mcp.Actions.McpTokenTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.McpConnection
  alias Rail.Mcp.Schemas.McpServer
  alias Rail.Users

  setup do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "mt_gh_#{id}", login: "mt_#{id}", email: "mt_#{id}@example.com"})

    {:ok, server} =
      Mcp.create_server(system_scope(), %{
        name: "linear_#{id}",
        url: "https://mcp.example.com/mcp",
        token_endpoint: "https://auth.example.com/token",
        client_id: "client_1"
      })

    %{user: user, server: server}
  end

  test "a server without auth needs no token" do
    assert {:ok, nil} = Mcp.mcp_token(nil, %McpServer{auth: :none})
  end

  test "an unconnected or missing user has no token", %{user: user, server: server} do
    assert {:error, :not_connected} = Mcp.mcp_token(user, server)
    assert {:error, :not_connected} = Mcp.mcp_token(nil, server)
  end

  test "returns a token that is not about to expire, or never does", %{user: user, server: server} do
    connection =
      Repo.insert!(%McpConnection{
        user_id: user.id,
        mcp_server_id: server.id,
        access_token: "at_fresh",
        expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
      })

    assert {:ok, "at_fresh"} = Mcp.mcp_token(user, server)

    connection |> Ecto.Changeset.change(expires_at: nil) |> Repo.update!()
    assert {:ok, "at_fresh"} = Mcp.mcp_token(user, server)
  end

  test "refreshes a token about to expire, keeping the refresh token the server did not rotate", %{
    user: user,
    server: server
  } do
    %{id: connection_id} =
      Repo.insert!(%McpConnection{
        user_id: user.id,
        mcp_server_id: server.id,
        access_token: "at_old",
        refresh_token: "rt_1",
        expires_at: DateTime.shift(DateTime.utc_now(), minute: 2)
      })

    Req.Test.expect(Mcp, fn conn ->
      assert %{"grant_type" => "refresh_token", "refresh_token" => "rt_1"} =
               conn |> Req.Test.raw_body() |> URI.decode_query()

      Req.Test.json(conn, %{"access_token" => "at_new", "expires_in" => 3600})
    end)

    assert {:ok, "at_new"} = Mcp.mcp_token(user, server)
    assert %McpConnection{access_token: "at_new", refresh_token: "rt_1"} = Repo.get!(McpConnection, connection_id)
  end

  test "force refreshes a token the server rejected", %{user: user, server: server} do
    Repo.insert!(%McpConnection{
      user_id: user.id,
      mcp_server_id: server.id,
      access_token: "at_old",
      refresh_token: "rt_1",
      expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
    })

    Req.Test.expect(Mcp, &Req.Test.json(&1, %{"access_token" => "at_new", "refresh_token" => "rt_2"}))

    assert {:ok, "at_new"} = Mcp.mcp_token(user, server, force: true)
  end

  test "fails when the token cannot be refreshed", %{user: user, server: server} do
    %{id: connection_id} =
      Repo.insert!(%McpConnection{
        user_id: user.id,
        mcp_server_id: server.id,
        access_token: "at_old",
        refresh_token: "rt_1",
        expires_at: DateTime.shift(DateTime.utc_now(), minute: -1)
      })

    Req.Test.expect(Mcp, &(&1 |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})))

    assert {:error, {:mcp_oauth_error, 400, _body}} = Mcp.mcp_token(user, server)
    assert %McpConnection{access_token: "at_old"} = Repo.get!(McpConnection, connection_id)

    McpConnection |> Repo.get!(connection_id) |> Ecto.Changeset.change(refresh_token: nil) |> Repo.update!()
    assert {:error, :token_expired} = Mcp.mcp_token(user, server)
  end
end
