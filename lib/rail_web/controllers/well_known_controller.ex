defmodule RailWeb.WellKnownController do
  use RailWeb, :controller

  # RFC 8414: where a person's Claude finds the consent page, the token endpoint and registration.
  def oauth_authorization_server(conn, _params) do
    issuer = RailWeb.Endpoint.url()

    json(conn, %{
      issuer: issuer,
      authorization_endpoint: issuer <> "/oauth/mcp/authorize",
      token_endpoint: issuer <> "/oauth/token",
      registration_endpoint: issuer <> "/oauth/register",
      scopes_supported: ["mcp"],
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none", "client_secret_basic", "client_secret_post"],
      client_id_metadata_document_supported: true
    })
  end

  # RFC 9728, served at the root and at the path-suffixed URL for `/mcp`.
  def oauth_protected_resource(conn, _params) do
    json(conn, %{
      resource: RailWeb.Endpoint.url() <> "/mcp",
      authorization_servers: [RailWeb.Endpoint.url()],
      scopes_supported: ["mcp"],
      bearer_methods_supported: ["header"]
    })
  end
end
