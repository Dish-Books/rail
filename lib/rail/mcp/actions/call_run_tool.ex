defmodule Rail.Mcp.Actions.CallRunTool do
  @moduledoc false

  import Rail.Mcp.Utils.ToolAllowed
  import Rail.Mcp.Utils.WithUpstreamToken

  alias Rail.Mcp.Client
  alias Rail.Mcp.RunContext
  alias Rail.Mcp.Schemas.McpServer
  alias Rail.Repo

  @doc """
  Forwards a `tools/call` for a proxied name (`<server name>__<tool>`) to its server, on
  the issue's assigned user's connection.

  The allowlist is checked again here rather than trusted from `tools/list`: an
  agent can call any name it likes. A name the role does not allow, or whose
  server is gone or disabled, is `{:error, :unknown_tool}`.
  """
  def call_run_tool(%RunContext{role: %{mcp_tools: mcp_tools}, user: user}, name, arguments) when is_binary(name) do
    with [server_name, tool] <- String.split(name, "__", parts: 2),
         true <- tool_allowed?(mcp_tools, server_name, tool),
         %McpServer{} = server <- Repo.get_by(McpServer, name: server_name, enabled: true) do
      with_upstream_token(user, server, &Client.call_tool(server.url, &1, tool, arguments || %{}))
    else
      _not_allowed -> {:error, :unknown_tool}
    end
  end

  def call_run_tool(_context, _name, _arguments), do: {:error, :unknown_tool}
end
