defmodule Rail.Mcp.Actions.Authorize do
  @moduledoc false

  import Rail.Mcp.Utils.GenerateToken
  import Rail.Mcp.Utils.ValidateAuthorization

  alias Rail.Mcp.Schemas.OauthAuthorizationCode
  alias Rail.Repo
  alias Rail.Scope

  @authorization_code_ttl_seconds 600

  @doc """
  A person's Allow: checks the request again and issues a code for them in a new token family. Returns the URL that
  sends the code and the client's `state` back to the client, or `{:error, :github_required}` for someone without GitHub.
  """
  def authorize(%Scope{user: %{github_id: nil}}, _params), do: {:error, :github_required}

  def authorize(%Scope{user: %{id: user_id}}, %{} = params) do
    with {:ok, client} <- validate_authorization(params) do
      {plaintext, selector, verifier_hash} = generate_token(:authorization_code)

      {:ok, _code} =
        %{
          selector: selector,
          verifier_hash: verifier_hash,
          family_id: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
          redirect_uri: params["redirect_uri"],
          expires_at: DateTime.shift(DateTime.utc_now(), second: @authorization_code_ttl_seconds),
          oauth_client_id: client.id,
          user_id: user_id,
          code_challenge: params["code_challenge"]
        }
        |> OauthAuthorizationCode.create_changeset()
        |> Repo.insert()

      {:ok,
       %{redirect_url: build_redirect_url(params["redirect_uri"], %{"code" => plaintext, "state" => params["state"]})}}
    end
  end

  defp build_redirect_url(redirect_uri, params) do
    uri = URI.parse(redirect_uri)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.merge(params)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
      |> URI.encode_query()

    URI.to_string(%{uri | query: query})
  end
end
