defmodule Rail.Mcp.ClientTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp.Client
  alias Rail.Mcp.Schemas.McpServer

  @url "https://mcp.example.com/mcp"

  describe "probe/1" do
    test "reports the resource metadata a 401 names" do
      Req.Test.expect(Rail.Mcp, fn conn ->
        assert %{"method" => "initialize"} = conn |> Req.Test.raw_body() |> Jason.decode!()

        conn
        |> Plug.Conn.put_resp_header(
          "www-authenticate",
          ~s(Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource")
        )
        |> Plug.Conn.send_resp(401, "")
      end)

      assert {:ok, {:auth_required, "https://mcp.example.com/.well-known/oauth-protected-resource"}} =
               Client.probe(@url)
    end

    test "reports no metadata when a 401 does not name any" do
      Req.Test.expect(Rail.Mcp, &Plug.Conn.send_resp(&1, 401, ""))

      assert {:ok, {:auth_required, nil}} = Client.probe(@url)
    end

    test "reports an open server" do
      Req.Test.expect(Rail.Mcp, &Req.Test.json(&1, %{"jsonrpc" => "2.0", "id" => 0, "result" => %{}}))

      assert {:ok, :open} = Client.probe(@url)
    end

    test "returns other statuses and transport errors" do
      Req.Test.expect(Rail.Mcp, &Plug.Conn.send_resp(&1, 500, "boom"))
      assert {:error, {:mcp_http_error, 500, "boom"}} = Client.probe(@url)

      Req.Test.expect(Rail.Mcp, &Req.Test.transport_error(&1, :econnrefused))
      assert {:error, %Req.TransportError{reason: :econnrefused}} = Client.probe(@url)
    end
  end

  describe "fetch_metadata/1" do
    test "returns the document, a bad status, or a transport error" do
      Req.Test.expect(Rail.Mcp, &Req.Test.json(&1, %{"issuer" => "https://auth.example.com"}))
      assert {:ok, %{"issuer" => "https://auth.example.com"}} = Client.fetch_metadata(@url)

      Req.Test.expect(Rail.Mcp, &Plug.Conn.send_resp(&1, 404, "missing"))
      assert {:error, {:mcp_metadata_error, 404, "missing"}} = Client.fetch_metadata(@url)

      Req.Test.expect(Rail.Mcp, &Req.Test.transport_error(&1, :timeout))
      assert {:error, %Req.TransportError{reason: :timeout}} = Client.fetch_metadata(@url)
    end
  end

  describe "register_client/1" do
    test "registers Rail as a public client with its callback" do
      redirect_uri = RailWeb.Endpoint.url() <> "/auth/mcp/callback"

      Req.Test.expect(Rail.Mcp, fn conn ->
        assert %{
                 "client_name" => "Rail",
                 "redirect_uris" => [^redirect_uri],
                 "token_endpoint_auth_method" => "none"
               } = conn |> Req.Test.raw_body() |> Jason.decode!()

        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"client_id" => "client_1"})
      end)

      assert {:ok, %{"client_id" => "client_1"}} = Client.register_client("https://auth.example.com/register")
    end

    test "returns a rejected registration and transport errors" do
      Req.Test.expect(Rail.Mcp, &(&1 |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid"})))

      assert {:error, {:mcp_registration_error, 400, %{"error" => "invalid"}}} =
               Client.register_client("https://auth.example.com/register")

      Req.Test.expect(Rail.Mcp, &Req.Test.transport_error(&1, :closed))

      assert {:error, %Req.TransportError{reason: :closed}} =
               Client.register_client("https://auth.example.com/register")
    end
  end

  describe "tokens" do
    setup do
      server = %McpServer{
        url: @url,
        resource: nil,
        token_endpoint: "https://auth.example.com/token",
        client_id: "client_1",
        client_secret: nil
      }

      %{server: server}
    end

    test "exchange_code/3 sends the verifier, resource and any client secret", %{server: server} do
      Req.Test.expect(Rail.Mcp, fn conn ->
        assert %{
                 "grant_type" => "authorization_code",
                 "code" => "code_1",
                 "code_verifier" => "verifier_1",
                 "client_id" => "client_1",
                 "client_secret" => "secret_1",
                 "resource" => @url
               } = conn |> Req.Test.raw_body() |> URI.decode_query()

        Req.Test.json(conn, %{"access_token" => "at_1"})
      end)

      assert {:ok, %{"access_token" => "at_1"}} =
               Client.exchange_code(%{server | client_secret: "secret_1"}, "code_1", "verifier_1")
    end

    test "refresh_token/2 leaves out a missing client secret", %{server: server} do
      Req.Test.expect(Rail.Mcp, fn conn ->
        form = conn |> Req.Test.raw_body() |> URI.decode_query()
        assert %{"grant_type" => "refresh_token", "refresh_token" => "rt_1"} = form
        refute Map.has_key?(form, "client_secret")

        Req.Test.json(conn, %{"access_token" => "at_2"})
      end)

      assert {:ok, %{"access_token" => "at_2"}} = Client.refresh_token(server, "rt_1")
    end

    test "returns token errors and transport errors", %{server: server} do
      Req.Test.expect(Rail.Mcp, &(&1 |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})))
      assert {:error, {:mcp_oauth_error, 400, %{"error" => "invalid_grant"}}} = Client.refresh_token(server, "rt_1")

      Req.Test.expect(Rail.Mcp, &Req.Test.transport_error(&1, :closed))
      assert {:error, %Req.TransportError{reason: :closed}} = Client.refresh_token(server, "rt_1")
    end
  end

  describe "list_tools/2" do
    test "initializes a session and follows pages to the end" do
      Req.Test.stub(Rail.Mcp, fn conn ->
        assert ["Bearer at_1"] = Plug.Conn.get_req_header(conn, "authorization")

        case conn |> Req.Test.raw_body() |> Jason.decode!() do
          %{"method" => "initialize", "id" => id} ->
            conn
            |> Plug.Conn.put_resp_header("mcp-session-id", "session_1")
            |> Req.Test.json(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"protocolVersion" => "2025-03-26"}})

          %{"method" => "notifications/initialized"} ->
            assert ["session_1"] = Plug.Conn.get_req_header(conn, "mcp-session-id")
            assert ["2025-03-26"] = Plug.Conn.get_req_header(conn, "mcp-protocol-version")
            Plug.Conn.send_resp(conn, 202, "")

          %{"method" => "tools/list", "id" => id, "params" => %{"cursor" => "page_2"}} ->
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => [%{"name" => "b"}]}})

          %{"method" => "tools/list", "id" => id} ->
            Req.Test.json(conn, %{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{"tools" => [%{"name" => "a"}], "nextCursor" => "page_2"}
            })
        end
      end)

      assert {:ok, [%{"name" => "a"}, %{"name" => "b"}]} = Client.list_tools(@url, "at_1")
    end

    test "reads responses from an event stream" do
      Req.Test.stub(Rail.Mcp, fn conn ->
        case conn |> Req.Test.raw_body() |> Jason.decode!() do
          %{"method" => "notifications/initialized"} ->
            Plug.Conn.send_resp(conn, 202, "")

          %{"id" => id} = message ->
            result = if message["method"] == "initialize", do: %{}, else: %{"tools" => [%{"name" => "sse"}]}
            response = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

            conn
            |> Plug.Conn.put_resp_content_type("text/event-stream")
            |> Plug.Conn.send_resp(200, "event: message\r\ndata: not json\r\n\r\nevent: message\ndata: #{response}\n\n")
        end
      end)

      assert {:ok, [%{"name" => "sse"}]} = Client.list_tools(@url, nil)
    end

    test "returns an unauthorized initialize and a JSON-RPC error" do
      Req.Test.expect(Rail.Mcp, &Plug.Conn.send_resp(&1, 401, ""))
      assert {:error, :unauthorized} = Client.list_tools(@url, "stale")

      Req.Test.expect(Rail.Mcp, fn conn ->
        Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 0, "error" => %{"code" => -32_000, "message" => "no"}})
      end)

      assert {:error, {:mcp_rpc_error, %{"message" => "no"}}} = Client.list_tools(@url, "at_1")
    end

    test "returns failures after initialize" do
      Req.Test.expect(Rail.Mcp, 2, fn conn ->
        case conn |> Req.Test.raw_body() |> Jason.decode!() do
          %{"method" => "initialize"} -> Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 0, "result" => %{}})
          %{"method" => "notifications/initialized"} -> Plug.Conn.send_resp(conn, 500, "down")
        end
      end)

      assert {:error, {:mcp_http_error, 500, "down"}} = Client.list_tools(@url, "at_1")

      Req.Test.expect(Rail.Mcp, 3, fn conn ->
        case conn |> Req.Test.raw_body() |> Jason.decode!() do
          %{"method" => "initialize"} -> Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 0, "result" => %{}})
          %{"method" => "notifications/initialized"} -> Plug.Conn.send_resp(conn, 202, "")
          %{"method" => "tools/list"} -> Req.Test.json(conn, [])
        end
      end)

      assert {:error, :mcp_no_response} = Client.list_tools(@url, "at_1")

      Req.Test.expect(Rail.Mcp, &Req.Test.transport_error(&1, :econnrefused))
      assert {:error, %Req.TransportError{reason: :econnrefused}} = Client.list_tools(@url, "at_1")
    end
  end

  describe "call_tool/4" do
    test "calls the tool without a token when the server needs none" do
      Req.Test.stub(Rail.Mcp, fn conn ->
        assert [] = Plug.Conn.get_req_header(conn, "authorization")

        case conn |> Req.Test.raw_body() |> Jason.decode!() do
          %{"method" => "initialize", "id" => id} ->
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})

          %{"method" => "notifications/initialized"} ->
            Plug.Conn.send_resp(conn, 202, "")

          %{"method" => "tools/call", "id" => id, "params" => %{"name" => "echo", "arguments" => %{"x" => 1}}} ->
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"content" => []}})
        end
      end)

      assert {:ok, %{"content" => []}} = Client.call_tool(@url, nil, "echo", %{"x" => 1})
    end
  end

  test "protocol_version/0 and config/0" do
    assert "2025-06-18" = Client.protocol_version()
    assert [req_options: [plug: {Req.Test, Rail.Mcp}, retry: false]] = Client.config()
  end
end
