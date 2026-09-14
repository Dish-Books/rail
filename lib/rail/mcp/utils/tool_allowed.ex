defmodule Rail.Mcp.Utils.ToolAllowed do
  @moduledoc false

  @doc """
  Whether a role's `mcp_tools` allow `tool` on the server `server_name`: named exactly
  (`linear__get_issue`) or through the server wildcard (`linear__*`).
  """
  def tool_allowed?(mcp_tools, server_name, tool)
      when is_list(mcp_tools) and is_binary(server_name) and is_binary(tool) do
    Enum.any?(mcp_tools, &(&1 in ["#{server_name}__*", "#{server_name}__#{tool}"]))
  end

  def tool_allowed?(_mcp_tools, _server_name, _tool), do: false
end
