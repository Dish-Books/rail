defmodule Rail.Mcp.Actions.CreateServer do
  @moduledoc false

  alias Rail.Mcp.Schemas.McpServer
  alias Rail.Repo

  def create_server(_scope, attrs) do
    %McpServer{}
    |> McpServer.changeset(attrs)
    |> Repo.insert()
  end
end
