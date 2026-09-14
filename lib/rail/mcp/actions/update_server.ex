defmodule Rail.Mcp.Actions.UpdateServer do
  @moduledoc false

  alias Rail.Mcp.Schemas.McpServer
  alias Rail.Repo

  def update_server(_scope, %McpServer{} = server, attrs) do
    server
    |> McpServer.changeset(attrs)
    |> Repo.update()
  end
end
