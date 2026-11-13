defmodule Rail.Mcp.Actions.RegisterDynamicClientTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.OauthClient

  test "registers a public client by default, with no secret" do
    assert {:ok,
            %OauthClient{
              name: "Claude Code",
              registration: :dynamic,
              token_endpoint_auth_method: :none,
              client_secret_hash: nil,
              redirect_uris: ["http://localhost/callback"]
            }, nil} =
             Mcp.register_dynamic_client(%{
               "client_name" => "Claude Code",
               "redirect_uris" => ["http://localhost/callback"],
               "grant_types" => ["authorization_code", "refresh_token"],
               "response_types" => ["code"]
             })
  end

  test "a confidential client sees its secret once, and Rail keeps only its hash" do
    assert {:ok, %OauthClient{token_endpoint_auth_method: :client_secret_post} = client, secret} =
             Mcp.register_dynamic_client(%{
               "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
               "token_endpoint_auth_method" => "client_secret_post"
             })

    expected_hash = :crypto.hash(:sha256, secret)
    assert %OauthClient{client_secret_hash: ^expected_hash} = client
  end

  test "a client with no name, or a blank one, is named for what it is" do
    assert {:ok, %OauthClient{name: "MCP client"}, nil} =
             Mcp.register_dynamic_client(%{"redirect_uris" => ["https://claude.ai/callback"]})

    assert {:ok, %OauthClient{name: "MCP client"}, nil} =
             Mcp.register_dynamic_client(%{"client_name" => "  ", "redirect_uris" => ["https://claude.ai/callback"]})
  end

  test "refuses metadata Rail does not support" do
    for metadata <- [
          %{"token_endpoint_auth_method" => "private_key_jwt"},
          %{"grant_types" => ["client_credentials"]},
          %{"response_types" => "code"}
        ] do
      assert {:error, :invalid_client_metadata} =
               Mcp.register_dynamic_client(Map.put(metadata, "redirect_uris", ["https://claude.ai/callback"]))
    end
  end

  test "refuses a redirect URI that is not https or a loopback http one" do
    for uris <- [[], ["http://example.com/callback"], ["https://claude.ai/callback#frag"], [42], nil] do
      assert {:error, :invalid_redirect_uri} = Mcp.register_dynamic_client(%{"redirect_uris" => uris})
    end
  end
end
