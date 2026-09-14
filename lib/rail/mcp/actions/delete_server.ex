defmodule Rail.Mcp.Actions.DeleteServer do
  @moduledoc false

  alias Rail.Mcp.Schemas.McpServer
  alias Rail.Repo

  # Connections go with it (`on_delete: :delete_all`); role allowlists that still
  # name it simply match nothing.
  def delete_server(_scope, %McpServer{} = server) do
    Repo.delete(server)
  end
end
