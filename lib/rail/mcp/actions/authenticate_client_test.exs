defmodule Rail.Mcp.Actions.AuthenticateClientTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.OauthClient

  test "a public client authenticates by its client_id alone" do
    {:ok, %OauthClient{id: id, client_id: client_id}, nil} =
      Mcp.register_dynamic_client(%{"redirect_uris" => ["https://claude.ai/callback"]})

    assert {:ok, %OauthClient{id: ^id}} = Mcp.authenticate_client(client_id, :none)
    assert {:error, :invalid_client} = Mcp.authenticate_client(client_id, {:client_secret_basic, "guess"})
  end

  test "a confidential client must send its secret the way it registered" do
    {:ok, %OauthClient{id: id, client_id: client_id}, secret} =
      Mcp.register_dynamic_client(%{
        "redirect_uris" => ["https://claude.ai/callback"],
        "token_endpoint_auth_method" => "client_secret_basic"
      })

    assert {:ok, %OauthClient{id: ^id}} = Mcp.authenticate_client(client_id, {:client_secret_basic, secret})
    assert {:error, :invalid_client} = Mcp.authenticate_client(client_id, {:client_secret_post, secret})
    assert {:error, :invalid_client} = Mcp.authenticate_client(client_id, {:client_secret_basic, "wrong"})
    assert {:error, :invalid_client} = Mcp.authenticate_client(client_id, :none)
  end

  test "an unknown client does not authenticate" do
    assert {:error, :invalid_client} = Mcp.authenticate_client("nobody", :none)
  end
end
