defmodule Rail.Mcp.Actions.AuthorizeTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.OauthAuthorizationCode
  alias Rail.Scope
  alias Rail.Users

  setup do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "az_#{id}",
        login: "az_#{id}",
        name: "Az #{id}",
        email: "az_#{id}@example.com"
      })

    {:ok, client, nil} = Mcp.register_dynamic_client(%{"redirect_uris" => ["http://localhost/callback?keep=1"]})

    params = %{
      "client_id" => client.client_id,
      "redirect_uri" => "http://localhost:7777/callback?keep=1",
      "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, "verifier"), padding: false),
      "code_challenge_method" => "S256"
    }

    %{user: user, client: client, params: params}
  end

  test "issues a code for the person in a new family and sends it back with the state", %{
    user: %{id: user_id} = user,
    client: %{id: client_id},
    params: params
  } do
    assert {:ok, %{redirect_url: url}} = Mcp.authorize(Scope.for_user(user), Map.put(params, "state", "s-1"))

    assert %URI{host: "localhost", port: 7777, path: "/callback", query: query} = URI.parse(url)
    assert %{"keep" => "1", "code" => "rail.ac." <> _rest, "state" => "s-1"} = URI.decode_query(query)

    assert [%OauthAuthorizationCode{user_id: ^user_id, oauth_client_id: ^client_id, consumed_at: nil}] =
             Repo.all(from(c in OauthAuthorizationCode, where: c.user_id == ^user_id))
  end

  test "sends no state when the client sent none", %{user: user, params: params} do
    assert {:ok, %{redirect_url: url}} = Mcp.authorize(Scope.for_user(user), params)
    refute Map.has_key?(URI.decode_query(URI.parse(url).query), "state")
  end

  test "issues nothing for a request that does not check out", %{user: %{id: user_id} = user, params: params} do
    assert {:error, :invalid_request} =
             Mcp.authorize(Scope.for_user(user), %{params | "redirect_uri" => "https://evil.example/callback"})

    assert [] = Repo.all(from(c in OauthAuthorizationCode, where: c.user_id == ^user_id))
  end

  test "issues nothing for someone who disconnected GitHub", %{user: %{id: user_id} = user, params: params} do
    {:ok, user} = Users.unlink_github(Scope.for_user(user))

    assert {:error, :github_required} = Mcp.authorize(Scope.for_user(user), params)
    assert [] = Repo.all(from(c in OauthAuthorizationCode, where: c.user_id == ^user_id))
  end
end
