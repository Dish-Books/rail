defmodule RailTest.McpHelpers do
  @moduledoc """
  Calls a tool of `RailWeb.Mcp.Server` in the test process, as the transport would for `scope`. Over HTTP each call
  runs in a task of its session, which a test's database sandbox and `Req.Test` stubs do not reach.
  """

  alias Anubis.Server.Frame

  @doc "Returns the tool's result as the client reads it: `{:ok, decoded_json_or_text}`, or `{:error, text}` with `isError`."
  def call_mcp_tool(scope, name, arguments) do
    request = %{"method" => "tools/call", "params" => %{"name" => name, "arguments" => arguments}}

    case RailWeb.Mcp.Server.handle_request(request, Frame.new(%{current_scope: scope})) do
      {:reply, %{"isError" => false, "content" => [%{"text" => text}]}, _frame} -> {:ok, JSON.decode!(text)}
      {:reply, %{"isError" => true, "content" => [%{"text" => text}]}, _frame} -> {:error, text}
      {:error, error, _frame} -> {:error, error}
    end
  end
end
