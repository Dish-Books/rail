defmodule Rail.Mcp.Actions.GetServer do
  @moduledoc false

  alias Rail.Mcp.Schemas.McpServer
  alias Rail.Repo

  def get_server(by) do
    case Repo.get_by(McpServer, by) do
      %McpServer{} = server -> {:ok, server}
      nil -> {:error, :not_found}
    end
  end
end
