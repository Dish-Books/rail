defmodule Rail.Mcp.Actions.AuthenticateClient do
  @moduledoc false

  import Rail.Mcp.Utils.FetchClient

  alias Rail.Mcp.Schemas.OauthClient

  @doc """
  Authenticates a client at the token endpoint by the method it registered: `{:client_secret_basic, secret}`,
  `{:client_secret_post, secret}`, or `:none` for a public client (RFC 6749 §2.3).
  """
  def authenticate_client(client_id, credential) when is_binary(client_id) do
    with {:ok, client} <- fetch_client(client_id),
         true <- valid_credential?(client, credential) do
      {:ok, client}
    else
      _failure -> {:error, :invalid_client}
    end
  end

  defp valid_credential?(%OauthClient{token_endpoint_auth_method: :none}, :none), do: true

  defp valid_credential?(%OauthClient{token_endpoint_auth_method: method, client_secret_hash: hash}, {method, secret})
       when is_binary(hash) and is_binary(secret), do: Plug.Crypto.secure_compare(:crypto.hash(:sha256, secret), hash)

  defp valid_credential?(_client, _credential), do: false
end
