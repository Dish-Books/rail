defmodule Rail.Mcp.Actions.RevokeAuthorization do
  @moduledoc false

  import Ecto.Query
  import Rail.Mcp.Utils.RevokeFamily

  alias Rail.Mcp.Schemas.OauthAuthorizationCode
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Revokes every token of one of the scope user's connections, by its family, and broadcasts
  `{:mcp_authorizations_changed, user_id}` on `"mcp_authorizations"`. Another person's family, or one already revoked,
  is `{:error, :not_found}`.
  """
  def revoke_authorization(%Scope{user: %{id: user_id}}, family_id) when is_binary(family_id) do
    fn ->
      owned? =
        Repo.exists?(from(c in OauthAuthorizationCode, where: c.family_id == ^family_id and c.user_id == ^user_id))

      if owned? and revoke_family(family_id) > 0, do: {:ok, :revoked}, else: {:error, :not_found}
    end
    |> Repo.transact()
    |> case do
      {:ok, :revoked} ->
        Phoenix.PubSub.broadcast(Rail.PubSub, "mcp_authorizations", {:mcp_authorizations_changed, user_id})
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end
end
