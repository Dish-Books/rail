defmodule Rail.Mcp.Actions.ConnectServer do
  @moduledoc false

  import Rail.Mcp.Utils.TokenExpiresAt

  alias Rail.Mcp.Client
  alias Rail.Mcp.Schemas.McpConnection
  alias Rail.Mcp.Schemas.McpServer
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Trades the OAuth callback's code for tokens and stores them as the scope's
  user's connection to the server, replacing any connection they already had.
  """
  def connect_server(%Scope{user: %{id: user_id}}, %McpServer{} = server, code, verifier)
      when is_binary(user_id) and is_binary(code) and is_binary(verifier) do
    with {:ok, tokens} <- Client.exchange_code(server, code, verifier) do
      %McpConnection{}
      |> McpConnection.changeset(%{
        user_id: user_id,
        mcp_server_id: server.id,
        access_token: tokens["access_token"],
        refresh_token: tokens["refresh_token"],
        expires_at: token_expires_at(tokens),
        scope: scope_string(tokens["scope"])
      })
      |> Repo.insert(
        on_conflict: {:replace, [:access_token, :refresh_token, :expires_at, :scope, :updated_at]},
        conflict_target: [:user_id, :mcp_server_id],
        returning: true
      )
    end
  end

  def connect_server(_scope, _server, _code, _verifier), do: {:error, :not_authenticated}

  defp scope_string(scopes) when is_list(scopes), do: Enum.join(scopes, " ")
  defp scope_string(scope) when is_binary(scope), do: scope
  defp scope_string(_none), do: nil
end
