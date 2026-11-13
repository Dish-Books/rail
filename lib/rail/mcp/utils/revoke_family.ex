defmodule Rail.Mcp.Utils.RevokeFamily do
  @moduledoc false

  import Ecto.Query

  alias Rail.Mcp.Schemas.OauthAccessToken
  alias Rail.Mcp.Schemas.OauthRefreshToken
  alias Rail.Repo

  @doc "Revokes every live access and refresh token of `family_id`, returning how many were revoked."
  def revoke_family(family_id) when is_binary(family_id) do
    now = DateTime.utc_now()

    {refresh_count, _rows} =
      Repo.update_all(from(t in OauthRefreshToken, where: t.family_id == ^family_id and is_nil(t.revoked_at)),
        set: [revoked_at: now]
      )

    {access_count, _rows} =
      Repo.update_all(from(t in OauthAccessToken, where: t.family_id == ^family_id and is_nil(t.revoked_at)),
        set: [revoked_at: now]
      )

    refresh_count + access_count
  end
end
