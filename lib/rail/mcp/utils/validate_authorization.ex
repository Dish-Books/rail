defmodule Rail.Mcp.Utils.ValidateAuthorization do
  @moduledoc """
  Checks the client, redirect URI, scope, resource and PKCE challenge of a consent request, both when the consent page
  opens and when Allow issues the code.
  """

  import Rail.Mcp.Utils.FetchClient

  @loopback_hosts ["localhost", "127.0.0.1", "::1"]

  @doc "Returns `{:ok, client}`, or the OAuth error the request earns."
  def validate_authorization(params) when is_map(params) do
    with {:ok, client} <- fetch_client(params["client_id"]),
         true <- redirect_uri_registered?(client.redirect_uris, params["redirect_uri"]) || {:error, :invalid_request},
         true <- params["scope"] in [nil, "mcp"] || {:error, :invalid_scope},
         true <- params["resource"] in [nil, RailWeb.Endpoint.url() <> "/mcp"] || {:error, :invalid_target},
         :ok <- validate_pkce(params["code_challenge"], params["code_challenge_method"]) do
      {:ok, client}
    end
  end

  # Exact, but an http loopback URI matches on any port, since a native client binds whichever is free (RFC 8252 §7.3).
  defp redirect_uri_registered?(registered, requested) when is_binary(requested) do
    requested = URI.parse(requested)

    Enum.any?(registered, fn uri ->
      uri = URI.parse(uri)

      uri.scheme == requested.scheme and uri.userinfo == requested.userinfo and uri.path == requested.path and
        uri.query == requested.query and uri.fragment == requested.fragment and
        is_binary(uri.host) and is_binary(requested.host) and String.downcase(uri.host) == String.downcase(requested.host) and
        (uri.port == requested.port or (uri.scheme == "http" and uri.host in @loopback_hosts))
    end)
  end

  defp redirect_uri_registered?(_registered, _requested), do: false

  # An S256 challenge is the unpadded base64url SHA-256 of the verifier, so always 43 characters (RFC 7636 §4.2).
  defp validate_pkce(challenge, "S256") when is_binary(challenge) and byte_size(challenge) == 43 do
    case Base.url_decode64(challenge, padding: false) do
      {:ok, _digest} -> :ok
      :error -> {:error, :invalid_pkce}
    end
  end

  defp validate_pkce(_challenge, _method), do: {:error, :invalid_pkce}
end
