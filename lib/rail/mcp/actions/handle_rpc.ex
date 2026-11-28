defmodule Rail.Mcp.Actions.HandleRpc do
  @moduledoc false

  alias Rail.Mcp

  require Logger

  @supported_versions ["2025-06-18", "2025-03-26", "2025-11-25"]

  @doc """
  Answers one JSON-RPC message from an agent authenticated as `context`: `{200, reply}` for a request, `{202, nil}`
  for a notification, `{400, reply}` for anything else. Rail's MCP server is stateless: one message in, one body out.
  Tool execution failures come back as a `CallToolResult` with `isError: true`, so the agent sees them.
  """
  def handle_rpc(context, %{"jsonrpc" => "2.0", "id" => id, "method" => method} = message) do
    {200, reply(id, dispatch(context, method, message["params"] || %{}))}
  end

  def handle_rpc(_context, %{"jsonrpc" => "2.0"}), do: {202, nil}

  def handle_rpc(_context, _invalid) do
    {400, %{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => -32_600, "message" => "Invalid Request"}}}
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

      {:error, {:refused, text}} ->
        {:ok, %{"content" => [%{"type" => "text", "text" => text}], "isError" => true}}

      {:error, {:rail_failed, reason}} ->
        Logger.warning("[mcp] #{params["name"]} failed: #{inspect(reason)}")
        text = "Rail could not run #{params["name"]}: #{if is_binary(reason), do: reason, else: inspect(reason)}"
        {:ok, %{"content" => [%{"type" => "text", "text" => text}], "isError" => true}}

      {:error, reason} ->
        Logger.warning("[mcp] #{params["name"]} failed: #{inspect(reason)}")
        {:ok, %{"content" => [%{"type" => "text", "text" => tool_error(reason)}], "isError" => true}}
    end
  end

  defp dispatch(_context, method, _params), do: {:error, -32_601, "Method not found: #{method}"}

  defp reply(id, {:ok, result}), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp reply(id, {:error, code, message}) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp tool_error(:not_connected), do: "The issue's assignee has not connected this MCP server in Rail."
  defp tool_error(:token_expired), do: "The assignee's connection to this MCP server has expired; reconnect it in Rail."
  defp tool_error({:mcp_rpc_error, %{"message" => message}}), do: message
  defp tool_error(reason), do: "MCP server request failed: #{inspect(reason)}"
end
