defmodule Rail.Mcp.Actions.ListConnections do
  @moduledoc false

  import Ecto.Query

  alias Rail.Mcp.Schemas.McpConnection
  alias Rail.Repo
  alias Rail.Scope

  def list_connections(%Scope{user: %{id: user_id}}) when is_binary(user_id) do
    Repo.all(from c in McpConnection, where: c.user_id == ^user_id)
  end

  def list_connections(_scope), do: []
end
