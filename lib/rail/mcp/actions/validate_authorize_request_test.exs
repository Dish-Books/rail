defmodule Rail.Mcp.Actions.ValidateAuthorizeRequestTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.OauthClient

  setup do
    {:ok, client, nil} =
      Mcp.register_dynamic_client(%{
        "client_name" => "Claude Code",
        "redirect_uris" => ["http://localhost/callback", "https://claude.ai/api/mcp/auth_callback"]
      })

    params = %{
      "client_id" => client.client_id,
      "redirect_uri" => "http://localhost:51234/callback",
      "response_type" => "code",
      "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, "verifier"), padding: false),
      "code_challenge_method" => "S256",
      "state" => "abc"
    }

    %{client: client, params: params}
  end

  test "returns the client for a request it can consent to", %{client: %OauthClient{id: id}, params: params} do
    assert {:ok, %OauthClient{id: ^id}} = Mcp.validate_authorize_request(params)

    assert {:ok, %OauthClient{id: ^id}} =
             %{
               params
               | "redirect_uri" => "https://CLAUDE.ai/api/mcp/auth_callback"
             }
             |> Map.put("scope", "mcp")
             |> Map.put("resource", RailWeb.Endpoint.url() <> "/mcp")
             |> Mcp.validate_authorize_request()
  end

  test "names what is wrong with a request", %{params: params} do
    for {change, error} <- [
          {%{"client_id" => "unknown"}, :invalid_client},
          {%{"client_id" => nil}, :invalid_client},
          {%{"redirect_uri" => "http://localhost:51234/elsewhere"}, :invalid_request},
          {%{"redirect_uri" => "https://claude.ai:8443/api/mcp/auth_callback"}, :invalid_request},
          {%{"redirect_uri" => "https://evil.example/callback"}, :invalid_request},
          {%{"redirect_uri" => nil}, :invalid_request},
          {%{"scope" => "admin"}, :invalid_scope},
          {%{"resource" => "https://elsewhere.example/mcp"}, :invalid_target},
          {%{"code_challenge_method" => "plain"}, :invalid_pkce},
          {%{"code_challenge" => "short"}, :invalid_pkce},
          {%{"code_challenge" => String.duplicate("!", 43)}, :invalid_pkce},
          {%{"response_type" => "token"}, :unsupported_response_type}
        ] do
      assert {:error, ^error} = Mcp.validate_authorize_request(Map.merge(params, change))
    end
  end
end
