defmodule RailWeb.WellKnownControllerTest do
  use RailWeb.ConnCase, async: true

  test "the protected-resource metadata names /mcp on Rail's own URL, at the root and under /mcp", %{conn: conn} do
    url = RailWeb.Endpoint.url()
    resource = url <> "/mcp"

    for path <- [~p"/.well-known/oauth-protected-resource", ~p"/.well-known/oauth-protected-resource/mcp"] do
      assert %{"resource" => ^resource, "authorization_servers" => [^url], "scopes_supported" => ["mcp"]} =
               conn |> get(path) |> json_response(200)
    end
  end

  test "the authorization-server metadata names Rail as issuer, S256, the consent page and the three endpoints", %{
    conn: conn
  } do
    url = RailWeb.Endpoint.url()
    authorize = url <> "/oauth/mcp/authorize"
    token = url <> "/oauth/token"
    register = url <> "/oauth/register"

    assert %{
             "issuer" => ^url,
             "authorization_endpoint" => ^authorize,
             "token_endpoint" => ^token,
             "registration_endpoint" => ^register,
             "code_challenge_methods_supported" => ["S256"],
             "client_id_metadata_document_supported" => true
           } = conn |> get(~p"/.well-known/oauth-authorization-server") |> json_response(200)
  end
end
