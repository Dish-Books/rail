defmodule RailWeb.McpController do
  @moduledoc """
  Rail's MCP server, over Streamable HTTP, for the agents it spawns.

  It is stateless: no `Mcp-Session-Id`, no server-initiated stream. Each POST is
  one JSON-RPC message answered with one JSON body, which is all an agent needs
  to list and call the tools Rail proxies. Tool execution failures come back as
  a `CallToolResult` with `isError: true`, so the agent sees them: a refused save
  with the reason to fix it, a failure of Rail's own tool as Rail's, and only a
  proxied server's as that server's. A name it may not call is a protocol error.
  """
  use RailWeb, :controller

  alias Rail.Mcp

  def handle(conn, _params) do
    case Mcp.handle_rpc(conn.assigns.mcp_context, conn.body_params) do
      {202, nil} -> send_resp(conn, 202, "")
      {status, reply} -> conn |> put_status(status) |> json(reply)
    end
  end

  def stream(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "")
  end
end
