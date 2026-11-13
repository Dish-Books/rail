defmodule RailWeb.OAuthAuthorizationController do
  use RailWeb, :controller

  alias Rail.Mcp

  def token(conn, params) do
    with {:ok, client_id, credential} <- client_credential(conn, params),
         {:ok, client} <- Mcp.authenticate_client(client_id, credential),
         {:ok, response} <- handle_grant(client, params) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("pragma", "no-cache")
      |> json(response)
    else
      :error ->
        deny_invalid_client(conn)

      {:error, :invalid_client} ->
        deny_invalid_client(conn)

      {:error, :unsupported_grant_type} ->
        deny(conn, 400, "unsupported_grant_type", "the grant_type is not supported")

      {:error, :invalid_request} ->
        deny(conn, 400, "invalid_request", "the request is missing a required parameter")

      {:error, :invalid_target} ->
        deny(conn, 400, "invalid_target", "the requested resource is not served by this authorization server")

      {:error, :invalid_grant} ->
        deny(conn, 400, "invalid_grant", "the authorization grant is invalid, expired, or revoked")
    end
  end

  # RFC 7591 registration, open to any MCP client; a Cloudflare rule limits how often.
  def register(conn, params) do
    case Mcp.register_dynamic_client(params) do
      {:ok, client, secret} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_status(201)
        |> json(
          Map.merge(
            %{
              client_id: client.client_id,
              client_id_issued_at: DateTime.to_unix(client.inserted_at),
              client_name: client.name,
              redirect_uris: client.redirect_uris,
              token_endpoint_auth_method: client.token_endpoint_auth_method,
              grant_types: ["authorization_code", "refresh_token"],
              response_types: ["code"],
              scope: "mcp"
            },
            # A confidential client sees its secret here and nowhere else; it never expires (RFC 7591 §3.2.1).
            if(secret, do: %{client_secret: secret, client_secret_expires_at: 0}, else: %{})
          )
        )

      {:error, :invalid_redirect_uri} ->
        deny(conn, 400, "invalid_redirect_uri", "redirect_uris must use https, or http on localhost")

      {:error, :invalid_client_metadata} ->
        deny(conn, 400, "invalid_client_metadata", "the client metadata is invalid or unsupported")
    end
  end

  # RFC 6749 §2.3.1: HTTP Basic first, then a secret in the body, then a public client's bare client_id.
  defp client_credential(conn, params) do
    case {Plug.BasicAuth.parse_basic_auth(conn), params} do
      {{client_id, secret}, _params} ->
        {:ok, client_id, {:client_secret_basic, secret}}

      {:error, %{"client_id" => client_id, "client_secret" => secret}} when is_binary(client_id) and is_binary(secret) ->
        {:ok, client_id, {:client_secret_post, secret}}

      {:error, %{"client_id" => client_id}} when is_binary(client_id) ->
        {:ok, client_id, :none}

      {:error, _params} ->
        :error
    end
  end

  defp handle_grant(client, %{"grant_type" => "authorization_code"} = params), do: Mcp.exchange_code(client, params)
  defp handle_grant(client, %{"grant_type" => "refresh_token"} = params), do: Mcp.refresh_token(client, params)
  defp handle_grant(_client, %{"grant_type" => _other}), do: {:error, :unsupported_grant_type}
  defp handle_grant(_client, _params), do: {:error, :invalid_request}

  defp deny(conn, status, error, description) do
    conn
    |> put_status(status)
    |> json(%{error: error, error_description: description})
  end

  defp deny_invalid_client(conn) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="oauth"))
    |> put_status(401)
    |> json(%{error: "invalid_client", error_description: "client authentication failed"})
  end
end
