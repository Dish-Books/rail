defmodule Rail.Mcp.Actions.ListAuthorizations do
  @moduledoc false

  import Ecto.Query

  alias Rail.Mcp.Schemas.OauthAccessToken
  alias Rail.Mcp.Schemas.OauthAuthorizationCode
  alias Rail.Mcp.Schemas.OauthRefreshToken
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  The scope user's connections, one per token family whose newest refresh token is live, newest first. Each is a map of
  `:family_id`, `:client_name`, `:redirect_host`, `:connected_at` and `:last_used_at`, which is when its newest token
  was issued until one is used.
  """
  def list_authorizations(%Scope{user: %{id: user_id}}) do
    now = DateTime.utc_now()

    live_refresh =
      from(r in OauthRefreshToken,
        where: r.family_id == parent_as(:code).family_id and r.user_id == ^user_id,
        where: is_nil(r.revoked_at) and r.expires_at > ^now,
        select: 1
      )

    from(c in OauthAuthorizationCode,
      as: :code,
      join: client in assoc(c, :client),
      join: a in OauthAccessToken,
      on: a.family_id == c.family_id and a.user_id == ^user_id,
      where: c.user_id == ^user_id and exists(live_refresh),
      group_by: [c.id, client.name],
      order_by: [desc: min(a.inserted_at), desc: c.family_id],
      select: %{
        family_id: c.family_id,
        client_name: client.name,
        redirect_uri: c.redirect_uri,
        connected_at: min(a.inserted_at),
        last_used_at: coalesce(max(a.last_used_at), max(a.inserted_at))
      }
    )
    |> Repo.all()
    |> Enum.map(fn %{redirect_uri: redirect_uri} = authorization ->
      authorization |> Map.delete(:redirect_uri) |> Map.put(:redirect_host, URI.parse(redirect_uri).host)
    end)
  end
end
