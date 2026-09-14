defmodule RailWeb.McpControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.RunContext
  alias Rail.Roles.Schemas.Role

  setup %{conn: conn} do
    context = %RunContext{role: %Role{mcp_tools: ["open__*"]}}

    stub(Mcp, :authenticate_run_token, fn
      "run_token" -> {:ok, context}
      _other -> {:error, :invalid_token}
    end)

    authed =
      conn
      |> put_req_header("authorization", "Bearer run_token")
      |> put_req_header("content-type", "application/json")

    %{authed: authed, context: context}
  end

  test "rejects a request without a run token", %{conn: conn} do
    conn = conn |> put_req_header("content-type", "application/json") |> post(~p"/mcp", "{}")

    assert %{"error" => "invalid_token"} = json_response(conn, 401)
  end

  test "initialize answers the client's version when supported, else its own", %{authed: conn} do
    message = %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{"protocolVersion" => "2025-03-26"}}

    assert %{
             "id" => 1,
             "result" => %{
               "protocolVersion" => "2025-03-26",
               "capabilities" => %{"tools" => %{}},
               "serverInfo" => %{"name" => "rail"}
             }
           } = conn |> post(~p"/mcp", Jason.encode!(message)) |> json_response(200)

    message = %{"jsonrpc" => "2.0", "id" => 2, "method" => "initialize"}

    assert %{"result" => %{"protocolVersion" => "2025-06-18"}} =
             conn |> post(~p"/mcp", Jason.encode!(message)) |> json_response(200)
  end

  test "accepts notifications and responses without a reply", %{authed: conn} do
    message = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}

    assert "" = conn |> post(~p"/mcp", Jason.encode!(message)) |> response(202)
  end

  test "answers ping, and an unknown method with method not found", %{authed: conn} do
    assert %{"id" => 3, "result" => %{}} =
             conn
             |> post(~p"/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 3, "method" => "ping"}))
             |> json_response(200)

    assert %{"id" => 4, "error" => %{"code" => -32_601}} =
             conn
             |> post(~p"/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 4, "method" => "resources/list"}))
             |> json_response(200)
  end

  test "rejects a body that is not a JSON-RPC message", %{authed: conn} do
    assert %{"error" => %{"code" => -32_600}} = conn |> post(~p"/mcp", ~s({"hello":"world"})) |> json_response(400)
  end

  test "tools/list lists the run's tools", %{authed: conn, context: context} do
    expect(Mcp, :list_run_tools, fn ^context -> {:ok, [%{"name" => "open__echo"}]} end)

    assert %{"result" => %{"tools" => [%{"name" => "open__echo"}]}} =
             conn
             |> post(~p"/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 5, "method" => "tools/list"}))
             |> json_response(200)
  end

  test "tools/call returns the upstream result, a protocol error, or a tool error", %{authed: conn, context: context} do
    call = fn name ->
      message = %{
        "jsonrpc" => "2.0",
        "id" => 6,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => %{"x" => 1}}
      }

      conn |> post(~p"/mcp", Jason.encode!(message)) |> json_response(200)
    end

    stub(Mcp, :call_run_tool, fn
      ^context, "open__ok", %{"x" => 1} -> {:ok, %{"content" => [%{"type" => "text", "text" => "hi"}]}}
      ^context, "open__nope", _arguments -> {:error, :unknown_tool}
      ^context, "open__unconnected", _arguments -> {:error, :not_connected}
      ^context, "open__expired", _arguments -> {:error, :token_expired}
      ^context, "open__rpc", _arguments -> {:error, {:mcp_rpc_error, %{"message" => "upstream said no"}}}
      ^context, "open__down", _arguments -> {:error, {:mcp_http_error, 503, ""}}
    end)

    assert %{"result" => %{"content" => [%{"text" => "hi"}]}} = call.("open__ok")
    assert %{"error" => %{"code" => -32_602, "message" => "Unknown tool: open__nope"}} = call.("open__nope")

    assert %{
             "result" => %{
               "isError" => true,
               "content" => [%{"text" => "The issue's assignee has not connected" <> _rest}]
             }
           } =
             call.("open__unconnected")

    assert %{"result" => %{"isError" => true, "content" => [%{"text" => "The assignee's connection" <> _rest}]}} =
             call.("open__expired")

    assert %{"result" => %{"isError" => true, "content" => [%{"text" => "upstream said no"}]}} = call.("open__rpc")

    assert %{"result" => %{"isError" => true, "content" => [%{"text" => "MCP server request failed: " <> _rest}]}} =
             call.("open__down")
  end

  test "GET offers no event stream", %{authed: conn} do
    conn = get(conn, ~p"/mcp")

    assert "" = response(conn, 405)
    assert ["POST"] = get_resp_header(conn, "allow")
  end
end
