defmodule Rail.Mcp.Actions.ExchangeCode do
  @moduledoc false

  import Ecto.Query
  import Rail.Mcp.Utils.IssueTokenPair
  import Rail.Mcp.Utils.ParseToken
  import Rail.Mcp.Utils.RevokeFamily
  import Rail.Mcp.Utils.VerifyToken

  alias Rail.Mcp.Schemas.OauthAuthorizationCode
  alias Rail.Mcp.Schemas.OauthClient
  alias Rail.Repo

  @doc """
  Exchanges a code for the first token pair of its family, once. A code exchanged before is a replay, which revokes
  every token of its family. Either way broadcasts `{:mcp_authorizations_changed, user_id}` on `"mcp_authorizations"`.
  """
  def exchange_code(%OauthClient{} = client, %{} = params) do
    cond do
      params["grant_type"] != "authorization_code" -> {:error, :unsupported_grant_type}
      params["resource"] not in [nil, RailWeb.Endpoint.url() <> "/mcp"] -> {:error, :invalid_target}
      true -> exchange(client, params)
    end
  end

  defp exchange(client, params) do
    fn ->
      with {:ok, code} <- authenticate_code(params["code"]) do
        cond do
          # Checked first, so a replay is caught whatever redirect URI or verifier the replayer sends. The revocation
          # must commit, so it returns `:ok` here and an error below (RFC 6819 §5.2.1.1).
          is_struct(code.consumed_at, DateTime) ->
            revoke_family(code.family_id)
            {:ok, {:replayed, code.user_id}}

          valid_request?(code, client, params) ->
            issue(client, code)

          true ->
            {:error, :invalid_grant}
        end
      end
    end
    |> Repo.transact()
    |> case do
      {:ok, {:replayed, user_id}} ->
        broadcast(user_id)
        {:error, :invalid_grant}

      {:ok, {user_id, tokens}} ->
        broadcast(user_id)
        {:ok, tokens}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Locks the code and checks its verifier, but not whether it was used: that is what tells a replay apart.
  defp authenticate_code(plaintext) do
    with {:ok, :authorization_code, selector, verifier} <- parse_token(plaintext),
         %OauthAuthorizationCode{} = code <-
           Repo.one(from(c in OauthAuthorizationCode, where: c.selector == ^selector, lock: "FOR UPDATE")),
         :ok <- verify_token(verifier, code.verifier_hash) do
      {:ok, code}
    else
      _failure -> {:error, :invalid_grant}
    end
  end

  defp valid_request?(code, client, params) do
    DateTime.after?(code.expires_at, DateTime.utc_now()) and code.oauth_client_id == client.id and
      code.redirect_uri == params["redirect_uri"] and verified_pkce?(code, params["code_verifier"])
  end

  defp verified_pkce?(%OauthAuthorizationCode{code_challenge: challenge}, verifier) do
    computed = Base.url_encode64(:crypto.hash(:sha256, if(is_binary(verifier), do: verifier, else: "")), padding: false)
    Plug.Crypto.secure_compare(computed, challenge)
  end

  defp issue(client, code) do
    with {:ok, _code} <- code |> OauthAuthorizationCode.consume_changeset(DateTime.utc_now()) |> Repo.update(),
         {:ok, pair} <- issue_token_pair(%{oauth_client_id: client.id, user_id: code.user_id, family_id: code.family_id}) do
      {:ok,
       {code.user_id,
        %{
          access_token: pair.plaintext_access_token,
          refresh_token: pair.plaintext_refresh_token,
          token_type: "Bearer",
          expires_in: pair.expires_in,
          scope: "mcp"
        }}}
    end
  end

  defp broadcast(user_id),
    do: Phoenix.PubSub.broadcast(Rail.PubSub, "mcp_authorizations", {:mcp_authorizations_changed, user_id})
end
