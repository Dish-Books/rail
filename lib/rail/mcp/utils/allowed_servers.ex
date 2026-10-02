defmodule Rail.Mcp.Utils.AllowedServers do
  @moduledoc false

  import Ecto.Query

  alias Rail.Mcp.Schemas.McpServer
  alias Rail.Repo

  @doc """
  The enabled servers a role's `mcp_tools` name at least one tool on, by name.
  """
  def allowed_servers(mcp_tools) when is_list(mcp_tools) do
    names = mcp_tools |> Enum.map(&(&1 |> String.split("__", parts: 2) |> hd())) |> Enum.uniq()

    Repo.all(from s in McpServer, where: s.enabled and s.name in ^names, order_by: [asc: s.name])
  end
end
