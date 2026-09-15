defmodule RailWeb.McpAuthControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.McpConnection
  alias Rail.Scope
  alias Rail.Users

  setup %{conn: conn} do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "mac_gh_#{id}", login: "mac_#{id}", email: "mac_#{id}@example.com"})

    {:ok, %{id: server_id} = server} =
      Mcp.create_server(system_scope(), %{
        name: "mac_linear",
        url: "https://mcp.example.com/mcp",
        authorization_endpoint: "https://auth.example.com/authorize",
        token_endpoint: "https://auth.example.com/token",
        client_id: "client_1"
      })

    %{authed_conn: log_in_user(conn, user), user: user, server: server, server_id: server_id}
  end

  describe "GET /auth/mcp/:server_id" do
    test "redirects to the server's authorization endpoint and remembers the flow", %{
      authed_conn: conn,
      server_id: server_id
    } do
      conn = get(conn, ~p"/auth/mcp/#{server_id}")

      assert "https://auth.example.com/authorize?" <> _query = redirected_to(conn, 302)
      assert %{"server_id" => ^server_id, "state" => _state, "verifier" => _verifier} = get_session(conn, :mcp_oauth)
    end

    test "refuses a server that is missing or not discovered", %{authed_conn: conn} do
      {:ok, %{id: undiscovered_id}} =
        Mcp.create_server(system_scope(), %{name: "mac_new", url: "https://new.example.com/mcp"})

      for id <- [undiscovered_id, "mcs_missing"] do
        conn = get(conn, ~p"/auth/mcp/#{id}")

        assert "/settings/connected-accounts" = redirected_to(conn)
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not ready to connect"
      end
    end

    test "requires a signed-in user", %{conn: conn, server_id: server_id} do
      assert "/sign-in" = conn |> get(~p"/auth/mcp/#{server_id}") |> redirected_to()
    end
  end

  describe "GET /auth/mcp/callback" do
    test "connects the user's account", %{authed_conn: conn, user: user, server_id: server_id} do
      Req.Test.expect(Mcp, fn conn ->
        assert %{"code" => "code_1", "code_verifier" => "verifier_1"} = conn |> Req.Test.raw_body() |> URI.decode_query()
        Req.Test.json(conn, %{"access_token" => "at_1", "refresh_token" => "rt_1", "expires_in" => 3600})
      end)

      conn =
        conn
        |> put_session(:mcp_oauth, %{"state" => "state_1", "verifier" => "verifier_1", "server_id" => server_id})
        |> get(~p"/auth/mcp/callback", %{"code" => "code_1", "state" => "state_1"})

      assert "/settings/connected-accounts" = redirected_to(conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Connected mac_linear."
      refute get_session(conn, :mcp_oauth)
      assert [%McpConnection{mcp_server_id: ^server_id}] = Mcp.list_connections(Scope.for_user(user))
    end

    test "fails on a forged state, a missing flow, or a failed exchange", %{authed_conn: conn, server_id: server_id} do
      pending = %{"state" => "state_1", "verifier" => "verifier_1", "server_id" => server_id}

      Req.Test.expect(Mcp, &(&1 |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})))

      conns = [
        conn |> put_session(:mcp_oauth, pending) |> get(~p"/auth/mcp/callback", %{"code" => "c", "state" => "forged"}),
        get(conn, ~p"/auth/mcp/callback", %{"code" => "c", "state" => "state_1"}),
        conn |> put_session(:mcp_oauth, pending) |> get(~p"/auth/mcp/callback", %{"code" => "c", "state" => "state_1"}),
        get(conn, ~p"/auth/mcp/callback", %{})
      ]

      for conn <- conns do
        assert "/settings/connected-accounts" = redirected_to(conn)
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "MCP server authentication failed."
      end
    end

    test "reports a denied authorization", %{authed_conn: conn} do
      conn = get(conn, ~p"/auth/mcp/callback", %{"error" => "access_denied"})

      assert "/settings/connected-accounts" = redirected_to(conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "denied or cancelled"
    end
  end
end
