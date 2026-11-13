defmodule RailWeb.Mcp.Server do
  @moduledoc """
  Rail's MCP server for people's own Claude, mounted at `/mcp` behind `RailWeb.Plugs.OAuth`. The transport copies the
  conn's assigns into each request's frame, so a tool reads the person from `frame.assigns.current_scope`.
  """

  use Anubis.Server,
    name: "rail",
    version: "1.0.0",
    capabilities: [:tools],
    instructions:
      "Rail tracks tickets in projects named by a key, such as RAIL in RAIL-12. Start with list_projects to see the keys."

  component(RailWeb.Mcp.Tools.ListProjects)
  component(RailWeb.Mcp.Tools.SearchIssues)
  component(RailWeb.Mcp.Tools.ListIssues)
  component(RailWeb.Mcp.Tools.GetIssue)
  component(RailWeb.Mcp.Tools.CreateIssue)
  component(RailWeb.Mcp.Tools.UpdateIssue)
  component(RailWeb.Mcp.Tools.CreateComment)

  @impl true
  def init(_client_info, frame), do: {:ok, frame}
end
