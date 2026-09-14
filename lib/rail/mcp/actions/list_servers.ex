defmodule Rail.Mcp.Actions.ListServers do
  @moduledoc false

  import Ecto.Query

  alias Rail.Mcp.Schemas.McpServer
  alias Rail.Repo

  def list_servers do
    Repo.all(from s in McpServer, order_by: [asc: s.name])
  end
end
