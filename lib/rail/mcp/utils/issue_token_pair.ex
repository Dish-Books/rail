defmodule Rail.Mcp.Utils.IssueTokenPair do
  @moduledoc """
  Inserts an access token and its refresh token in one family, for a code's exchange and a refresh's rotation.
  """

  import Rail.Mcp.Utils.GenerateToken

  alias Rail.Mcp.Schemas.OauthAccessToken
  alias Rail.Mcp.Schemas.OauthRefreshToken
  alias Rail.Repo

  @access_token_ttl_seconds 3_600
  @refresh_token_ttl_seconds 60 * 86_400

  @doc """
  Takes `:oauth_client_id`, `:user_id` and `:family_id`, and returns both rows, both plaintexts and the access token's
  lifetime in seconds.
  """
  def issue_token_pair(%{oauth_client_id: client_id, user_id: user_id, family_id: family_id}) do
    {access_plaintext, access_selector, access_hash} = generate_token(:access_token)
    {refresh_plaintext, refresh_selector, refresh_hash} = generate_token(:refresh_token)
    now = DateTime.utc_now()

    with {:ok, access_token} <-
           %OauthAccessToken{oauth_client_id: client_id, user_id: user_id, family_id: family_id}
           |> OauthAccessToken.create_changeset(%{
             selector: access_selector,
             verifier_hash: access_hash,
             expires_at: DateTime.shift(now, second: @access_token_ttl_seconds)
           })
           |> Repo.insert(),
         {:ok, refresh_token} <-
           %OauthRefreshToken{
             oauth_client_id: client_id,
             user_id: user_id,
             family_id: family_id,
             access_token_id: access_token.id
           }
           |> OauthRefreshToken.create_changeset(%{
             selector: refresh_selector,
             verifier_hash: refresh_hash,
             expires_at: DateTime.shift(now, second: @refresh_token_ttl_seconds)
           })
           |> Repo.insert() do
      {:ok,
       %{
         access_token: access_token,
         refresh_token: refresh_token,
         plaintext_access_token: access_plaintext,
         plaintext_refresh_token: refresh_plaintext,
         expires_in: @access_token_ttl_seconds
       }}
    end
  end
end
