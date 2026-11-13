defmodule Rail.Mcp.Actions.RefreshToken do
  @moduledoc false

  import Ecto.Query
  import Rail.Mcp.Utils.IssueTokenPair
  import Rail.Mcp.Utils.ParseToken
  import Rail.Mcp.Utils.RevokeFamily
  import Rail.Mcp.Utils.VerifyToken

  alias Rail.Mcp.Schemas.OauthAccessToken
  alias Rail.Mcp.Schemas.OauthClient
  alias Rail.Mcp.Schemas.OauthRefreshToken
  alias Rail.Repo

  @doc """
  Rotates a refresh token into a new pair of its family. One already rotated away is a reuse, which revokes the whole
  family. Either way broadcasts `{:mcp_authorizations_changed, user_id}` on `"mcp_authorizations"`.
  """
  def refresh_token(%OauthClient{} = client, %{} = params) do
    if params["grant_type"] == "refresh_token",
      do: refresh(client, params["refresh_token"]),
      else: {:error, :unsupported_grant_type}
  end

  defp refresh(client, plaintext) do
    fn ->
      with {:ok, refresh_token} <- lock_and_authenticate(client, plaintext) do
        rotate(client, refresh_token)
      end
    end
    |> Repo.transact()
    |> case do
      {:ok, {:reused, user_id}} ->
        broadcast(user_id)
        {:error, :invalid_grant}

      {:ok, {user_id, pair}} ->
        broadcast(user_id)

        {:ok,
         %{
           access_token: pair.plaintext_access_token,
           refresh_token: pair.plaintext_refresh_token,
           token_type: "Bearer",
           expires_in: pair.expires_in,
           scope: "mcp"
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A rotated token presented again was likely stolen, so its family goes.
  defp rotate(_client, %OauthRefreshToken{revoked_at: %DateTime{}} = refresh_token) do
    revoke_family(refresh_token.family_id)
    {:ok, {:reused, refresh_token.user_id}}
  end

  defp rotate(client, %OauthRefreshToken{} = refresh_token) do
    now = DateTime.utc_now()

    if DateTime.before?(refresh_token.expires_at, now) do
      {:error, :invalid_grant}
    else
      {:ok, _refresh_token} = refresh_token |> OauthRefreshToken.revoke_changeset(now) |> Repo.update()
      {:ok, _access_token} = refresh_token.access_token |> OauthAccessToken.revoke_changeset(now) |> Repo.update()

      with {:ok, pair} <-
             issue_token_pair(%{
               oauth_client_id: client.id,
               user_id: refresh_token.user_id,
               family_id: refresh_token.family_id
             }),
           do: {:ok, {refresh_token.user_id, pair}}
    end
  end

  defp lock_and_authenticate(%OauthClient{id: client_id}, plaintext) do
    with {:ok, :refresh_token, selector, verifier} <- parse_token(plaintext),
         %OauthRefreshToken{oauth_client_id: ^client_id} = refresh_token <-
           Repo.one(
             from(t in OauthRefreshToken, where: t.selector == ^selector, lock: "FOR UPDATE", preload: :access_token)
           ),
         :ok <- verify_token(verifier, refresh_token.verifier_hash) do
      {:ok, refresh_token}
    else
      _failure -> {:error, :invalid_grant}
    end
  end

  defp broadcast(user_id),
    do: Phoenix.PubSub.broadcast(Rail.PubSub, "mcp_authorizations", {:mcp_authorizations_changed, user_id})
end
