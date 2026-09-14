defmodule Rail.Mcp.Actions.DisconnectServer do
  @moduledoc false

  import Ecto.Query

  alias Rail.Mcp.Schemas.McpConnection
  alias Rail.Mcp.Schemas.McpServer
  alias Rail.Repo
  alias Rail.Scope

  def disconnect_server(%Scope{user: %{id: user_id}}, %McpServer{id: server_id}) when is_binary(user_id) do
    Repo.delete_all(from c in McpConnection, where: c.user_id == ^user_id and c.mcp_server_id == ^server_id)
    :ok
  end

  def disconnect_server(_scope, _server), do: {:error, :not_authenticated}
end
