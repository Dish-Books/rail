defmodule Rail.Mcp.Actions.McpToken do
  @moduledoc false

  import Ecto.Query
  import Rail.Mcp.Utils.TokenExpiresAt

  alias Rail.Mcp.Client
  alias Rail.Mcp.Schemas.McpConnection
  alias Rail.Mcp.Schemas.McpServer
  alias Rail.Repo

  @expiry_threshold_seconds 300

  @doc """
  The user's access token for the server, refreshed first when it is about to
  expire or when `force: true` says the server already rejected it. A server
  that needs no account answers `{:ok, nil}`.

  The connection row is locked while it refreshes. Servers rotate refresh
  tokens, so two tool calls refreshing at once would otherwise spend the same
  one and leave the connection holding a dead token.
  """
  def mcp_token(_user, %McpServer{auth: :none}, _opts), do: {:ok, nil}

  def mcp_token(%{id: user_id}, %McpServer{id: server_id} = server, opts) when is_binary(user_id) do
    Repo.transaction(fn ->
      query =
        from c in McpConnection,
          where: c.user_id == ^user_id and c.mcp_server_id == ^server_id,
          lock: "FOR UPDATE"

      case Repo.one(query) do
        %McpConnection{} = connection -> fresh_token(connection, server, Keyword.get(opts, :force, false))
        nil -> Repo.rollback(:not_connected)
      end
    end)
  end

  def mcp_token(_user, _server, _opts), do: {:error, :not_connected}

  defp fresh_token(connection, server, force) do
    if force or expiring?(connection.expires_at) do
      refresh(connection, server)
    else
      connection.access_token
    end
  end

  defp expiring?(%DateTime{} = expires_at) do
    DateTime.compare(expires_at, DateTime.shift(DateTime.utc_now(), second: @expiry_threshold_seconds)) != :gt
  end

  defp expiring?(_never), do: false

  defp refresh(%McpConnection{refresh_token: refresh_token} = connection, server) when is_binary(refresh_token) do
    case Client.refresh_token(server, refresh_token) do
      {:ok, tokens} ->
        connection
        |> McpConnection.changeset(%{
          access_token: tokens["access_token"],
          refresh_token: tokens["refresh_token"] || refresh_token,
          expires_at: token_expires_at(tokens)
        })
        |> Repo.update!()

        tokens["access_token"]

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp refresh(_connection, _server), do: Repo.rollback(:token_expired)
end
