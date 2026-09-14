defmodule Rail.Mcp.Actions.RefreshServerTools do
  @moduledoc false

  import Rail.Mcp.Utils.WithUpstreamToken

  alias Rail.Mcp.Client
  alias Rail.Mcp.Schemas.McpServer
  alias Rail.Repo

  @doc """
  Reads the server's tool list on the admin's own connection and caches the
  names and descriptions, which is what the role editor offers to allow.
  """
  def refresh_server_tools(scope, %McpServer{} = server) do
    with {:ok, tools} <- with_upstream_token(scope.user, server, &Client.list_tools(server.url, &1)) do
      server
      |> McpServer.changeset(%{
        tools: Enum.map(tools, &Map.take(&1, ["name", "description"])),
        tools_refreshed_at: DateTime.utc_now()
      })
      |> Repo.update()
    end
  end
end
