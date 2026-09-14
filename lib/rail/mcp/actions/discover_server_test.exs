defmodule Rail.Mcp.Actions.DiscoverServerTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.McpServer

  setup do
    {:ok, server} =
      Mcp.create_server(system_scope(), %{name: "dis_example", url: "https://mcp.example.com/mcp"})

    %{server: server}
  end

  test "marks a server that answers without a token as needing no auth", %{server: server} do
    Req.Test.expect(Mcp, &Req.Test.json(&1, %{"jsonrpc" => "2.0", "id" => 0, "result" => %{}}))

    assert {:ok, %McpServer{auth: :none}} = Mcp.discover_server(system_scope(), server)
  end

  test "follows the protected resource metadata and registers a client", %{server: server} do
    Req.Test.stub(Mcp, fn conn ->
      case {conn.method, conn.host, conn.request_path} do
        {"POST", "mcp.example.com", "/mcp"} ->
          conn
          |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer resource_metadata="https://mcp.example.com/prm"))
          |> Plug.Conn.send_resp(401, "")

        {"GET", "mcp.example.com", "/prm"} ->
          Req.Test.json(conn, %{
            "resource" => "https://mcp.example.com/mcp",
            "authorization_servers" => ["https://auth.example.com"],
            "scopes_supported" => ["read"]
          })

        {"GET", "auth.example.com", "/.well-known/oauth-authorization-server"} ->
          Req.Test.json(conn, %{
            "authorization_endpoint" => "https://auth.example.com/authorize",
            "token_endpoint" => "https://auth.example.com/token",
            "registration_endpoint" => "https://auth.example.com/register"
          })

        {"POST", "auth.example.com", "/register"} ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"client_id" => "client_1", "client_secret" => "secret_1"})
      end
    end)

    assert {:ok,
            %McpServer{
              auth: :oauth,
              resource: "https://mcp.example.com/mcp",
              authorization_endpoint: "https://auth.example.com/authorize",
              token_endpoint: "https://auth.example.com/token",
              scopes: ["read"],
              client_id: "client_1",
              client_secret: "secret_1"
            }} = Mcp.discover_server(system_scope(), server)
  end

  test "falls back to the server's origin and keeps a client it already has", %{server: server} do
    {:ok, server} = Mcp.update_server(system_scope(), server, %{client_id: "existing"})

    Req.Test.stub(Mcp, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/mcp"} ->
          Plug.Conn.send_resp(conn, 401, "")

        {"GET", "/.well-known/openid-configuration"} ->
          Req.Test.json(conn, %{
            "authorization_endpoint" => "https://mcp.example.com/authorize",
            "token_endpoint" => "https://mcp.example.com/token"
          })

        {"GET", _other} ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)

    assert {:ok, %McpServer{auth: :oauth, client_id: "existing", resource: "https://mcp.example.com/mcp", scopes: []}} =
             Mcp.discover_server(system_scope(), server)
  end

  test "tries the issuer's own openid configuration for an issuer with a path", %{server: server} do
    Req.Test.stub(Mcp, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/mcp"} ->
          Plug.Conn.send_resp(conn, 401, "")

        {"GET", "/.well-known/oauth-protected-resource/mcp"} ->
          Req.Test.json(conn, %{"authorization_servers" => ["https://auth.example.com/tenant/"]})

        {"GET", "/tenant/.well-known/openid-configuration"} ->
          Req.Test.json(conn, %{
            "authorization_endpoint" => "https://auth.example.com/tenant/authorize",
            "token_endpoint" => "https://auth.example.com/tenant/token"
          })

        {"GET", _other} ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)

    assert {:error, :no_registration_endpoint} = Mcp.discover_server(system_scope(), server)
  end

  test "fails without authorization server metadata, or when the server is unreachable", %{server: server} do
    Req.Test.stub(Mcp, fn conn ->
      case conn.method do
        "POST" -> Plug.Conn.send_resp(conn, 401, "")
        "GET" -> Req.Test.transport_error(conn, :econnrefused)
      end
    end)

    assert {:error, :authorization_server_not_found} = Mcp.discover_server(system_scope(), server)

    Req.Test.stub(Mcp, &Plug.Conn.send_resp(&1, 500, "down"))
    assert {:error, {:mcp_http_error, 500, "down"}} = Mcp.discover_server(system_scope(), server)
  end

  test "returns a failed registration", %{server: server} do
    Req.Test.stub(Mcp, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/mcp"} ->
          Plug.Conn.send_resp(conn, 401, "")

        {"GET", "/.well-known/oauth-authorization-server"} ->
          Req.Test.json(conn, %{
            "authorization_endpoint" => "https://mcp.example.com/authorize",
            "token_endpoint" => "https://mcp.example.com/token",
            "registration_endpoint" => "https://mcp.example.com/register"
          })

        {"POST", "/register"} ->
          Plug.Conn.send_resp(conn, 403, "closed")

        {"GET", _other} ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)

    assert {:error, {:mcp_registration_error, 403, "closed"}} = Mcp.discover_server(system_scope(), server)
  end

  test "is admin only", %{server: server} do
    assert {:error, :not_authorized} = Mcp.discover_server(user_scope(), server)
  end
end
