defmodule RailWeb.Utils.FindMcpAssignee do
  @moduledoc """
  Reads the assignee an MCP tool was given, `me` or a GitHub login, as a user id.
  """

  alias Rail.Users

  @doc "Returns `{:ok, nil}` for none, `{:ok, user_id}`, or `{:error, {:invalid, :assignee, detail}}`."
  def find_mcp_assignee(_scope, nil), do: {:ok, nil}

  def find_mcp_assignee(scope, login) do
    case {String.trim(login), Users.list_users_by_logins([String.trim(login)])} do
      {"me", _users} -> {:ok, scope.user.id}
      {_login, [user | _rest]} -> {:ok, user.id}
      {login, []} -> {:error, {:invalid, :assignee, "#{login} is no one in Rail"}}
    end
  end
end
