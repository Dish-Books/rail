defmodule Rail.Users.Actions.RemoveUser do
  @moduledoc false

  import Ecto.Query

  alias Rail.Mcp.Schemas.OauthAccessToken
  alias Rail.Mcp.Schemas.OauthRefreshToken
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User
  alias Rail.Users.Schemas.UserToken

  @doc """
  Takes someone out of Rail while keeping their row, so their name stays on the comments, tickets and merges they
  made. Signs them out everywhere, revokes their MCP connections and drops their admin, tech lead and Slack
  notifications, so a later invite decides afresh what they get. Broadcasts `{:users_changed, id}` on `"users"` and
  `{:user_removed, id}` on `"user:<id>"`, which every page they have open listens on. An admin cannot remove themselves.
  """
  def remove_user(%Scope{user: %User{id: id}}, id), do: {:error, :self}

  def remove_user(%Scope{}, user_id) when is_binary(user_id) do
    now = DateTime.utc_now()

    fn ->
      case Repo.one(from u in User, where: u.id == ^user_id and is_nil(u.removed_at), lock: "FOR UPDATE") do
        %User{} = user ->
          Repo.delete_all(from t in UserToken, where: t.user_id == ^user.id)
          revoke_mcp_tokens(user.id, now)

          user
          |> Ecto.Changeset.change(
            removed_at: now,
            admin: false,
            tech_lead: false,
            slack_notifications: false,
            slack_support_notifications: false
          )
          |> Repo.update()

        nil ->
          {:error, :not_found}
      end
    end
    |> Repo.transact()
    |> case do
      {:ok, user} ->
        Phoenix.PubSub.broadcast(Rail.PubSub, "users", {:users_changed, user.id})
        Phoenix.PubSub.broadcast(Rail.PubSub, "user:#{user.id}", {:user_removed, user.id})
        Phoenix.PubSub.broadcast(Rail.PubSub, "mcp_authorizations", {:mcp_authorizations_changed, user.id})
        {:ok, user}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp revoke_mcp_tokens(user_id, now) do
    for schema <- [OauthRefreshToken, OauthAccessToken] do
      Repo.update_all(from(t in schema, where: t.user_id == ^user_id and is_nil(t.revoked_at)), set: [revoked_at: now])
    end
  end
end
