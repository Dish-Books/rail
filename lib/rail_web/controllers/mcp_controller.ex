defmodule RailWeb.McpController do
  @moduledoc """
  Rail's MCP server, over Streamable HTTP, for the agents it spawns.

  It is stateless: no `Mcp-Session-Id`, no server-initiated stream. Each POST is
  one JSON-RPC message answered with one JSON body, which is all an agent needs
  to list and call the tools Rail proxies. Tool execution failures come back as
  a `CallToolResult` with `isError: true`, so the agent sees them; a name it may
  not call is a protocol error.
  """
  use RailWeb, :controller

  alias Rail.Mcp

  require Logger

  @supported_versions ["2025-06-18", "2025-03-26", "2025-11-25"]

  def handle(conn, _params) do
    case conn.body_params do
      %{"jsonrpc" => "2.0", "id" => id, "method" => method} = message ->
        reply(conn, id, dispatch(conn.assigns.mcp_context, method, message["params"] || %{}))

      %{"jsonrpc" => "2.0"} ->
        send_resp(conn, 202, "")

      _invalid ->
        conn
        |> put_status(400)
        |> json(%{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => -32_600, "message" => "Invalid Request"}})
    end
  end

  def stream(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "")
  end

  defp dispatch(_context, "initialize", params) do
    requested = params["protocolVersion"]
    version = if requested in @supported_versions, do: requested, else: hd(@supported_versions)

    {:ok,
     %{
       "protocolVersion" => version,
       "capabilities" => %{"tools" => %{"listChanged" => false}},
       "serverInfo" => %{"name" => "rail", "version" => "1.0.0"}
     }}
  end

  defp dispatch(_context, "ping", _params), do: {:ok, %{}}

  defp dispatch(context, "tools/list", _params) do
    {:ok, tools} = Mcp.list_run_tools(context)
    {:ok, %{"tools" => tools}}
  end

  defp dispatch(context, "tools/call", params) do
    case Mcp.call_run_tool(context, params["name"], params["arguments"]) do
      {:ok, result} ->
        {:ok, result}

      {:error, :unknown_tool} ->
        {:error, -32_602, "Unknown tool: #{params["name"]}"}

      {:error, reason} ->
        Logger.warning("[mcp] #{params["name"]} failed: #{inspect(reason)}")
        {:ok, %{"content" => [%{"type" => "text", "text" => tool_error(reason)}], "isError" => true}}
    end
  end

  defp dispatch(_context, method, _params), do: {:error, -32_601, "Method not found: #{method}"}

  defp reply(conn, id, {:ok, result}), do: json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp reply(conn, id, {:error, code, message}) do
    json(conn, %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}})
  end

  defp tool_error(:not_connected), do: "The issue's assignee has not connected this MCP server in Rail."
  defp tool_error(:token_expired), do: "The assignee's connection to this MCP server has expired; reconnect it in Rail."
  defp tool_error({:mcp_rpc_error, %{"message" => message}}), do: message
  defp tool_error(reason), do: "MCP server request failed: #{inspect(reason)}"
end
