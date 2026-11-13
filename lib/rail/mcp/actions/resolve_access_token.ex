defmodule Rail.Mcp.Actions.ResolveAccessToken do
  @moduledoc false

  import Ecto.Query
  import Rail.Mcp.Utils.ParseToken
  import Rail.Mcp.Utils.VerifyToken

  alias Rail.Mcp.Schemas.OauthAccessToken
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  The scope a bearer token for `/mcp` acts as: its user's. Returns `{:error, :invalid_token}`, `:revoked` or `:expired`
  for a token that does not resolve, and `:github_required` once its user has disconnected GitHub. Marks the token used at most once a minute, and broadcasts
  `{:mcp_authorizations_changed, user_id}` on `"mcp_authorizations"` when it does.
  """
  def resolve_access_token(plaintext) do
    now = DateTime.utc_now()

    with {:ok, :access_token, selector, verifier} <- parse_token(plaintext),
         %OauthAccessToken{} = token <-
           Repo.one(from(t in OauthAccessToken, where: t.selector == ^selector, preload: :user)),
         :ok <- verify_token(verifier, token.verifier_hash),
         nil <- token.revoked_at,
         true <- DateTime.after?(token.expires_at, now),
         %{github_id: github_id} when is_binary(github_id) <- token.user do
      touch_last_used(token, now)
      {:ok, Scope.for_user(token.user)}
    else
      %DateTime{} -> {:error, :revoked}
      false -> {:error, :expired}
      %{github_id: nil} -> {:error, :github_required}
      _unknown -> {:error, :invalid_token}
    end
  end

  # Through `update_all`, so two requests in the same minute write once between them.
  defp touch_last_used(%OauthAccessToken{} = token, now) do
    cutoff = DateTime.shift(now, minute: -1)

    if is_nil(token.last_used_at) or DateTime.before?(token.last_used_at, cutoff) do
      {count, _rows} =
        Repo.update_all(
          from(t in OauthAccessToken,
            where: t.id == ^token.id and (is_nil(t.last_used_at) or t.last_used_at < ^cutoff)
          ),
          set: [last_used_at: now]
        )

      if count == 1,
        do: Phoenix.PubSub.broadcast(Rail.PubSub, "mcp_authorizations", {:mcp_authorizations_changed, token.user_id})
    end
  end
end
