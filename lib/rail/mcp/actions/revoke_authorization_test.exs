defmodule Rail.Mcp.Actions.RevokeAuthorizationTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Scope
  alias Rail.Users

  setup do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "ra_#{id}",
        login: "ra_#{id}",
        name: "Ra #{id}",
        email: "ra_#{id}@example.com"
      })

    {:ok, other} =
      Users.register_oauth_user(%{
        github_id: "rb_#{id}",
        login: "rb_#{id}",
        name: "Rb #{id}",
        email: "rb_#{id}@example.com"
      })

    {:ok, client, nil} = Mcp.register_dynamic_client(%{"redirect_uris" => ["http://localhost/callback"]})

    connect = fn person ->
      verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      {:ok, %{redirect_url: url}} =
        Mcp.authorize(Scope.for_user(person), %{
          "client_id" => client.client_id,
          "redirect_uri" => "http://localhost/callback",
          "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
          "code_challenge_method" => "S256"
        })

      {:ok, %{access_token: access_token}} =
        Mcp.exchange_code(client, %{
          "grant_type" => "authorization_code",
          "code" => URI.decode_query(URI.parse(url).query)["code"],
          "redirect_uri" => "http://localhost/callback",
          "code_verifier" => verifier
        })

      access_token
    end

    Phoenix.PubSub.subscribe(Rail.PubSub, "mcp_authorizations")
    %{user: user, other: other, connect: connect}
  end

  test "revokes one connection at once and leaves the person's others working", %{
    user: %{id: user_id} = user,
    connect: connect
  } do
    first = connect.(user)
    second = connect.(user)
    scope = Scope.for_user(user)
    [%{family_id: family_id}, %{family_id: kept_family}] = Mcp.list_authorizations(scope)

    assert :ok = Mcp.revoke_authorization(scope, family_id)
    assert_receive {:mcp_authorizations_changed, ^user_id}
    assert [%{family_id: ^kept_family}] = Mcp.list_authorizations(scope)
    assert [{:error, :revoked}, {:ok, %Scope{}}] = [Mcp.resolve_access_token(second), Mcp.resolve_access_token(first)]
  end

  test "a person cannot revoke another person's connection by its id", %{user: user, other: other, connect: connect} do
    access_token = connect.(other)
    [%{family_id: family_id}] = Mcp.list_authorizations(Scope.for_user(other))

    assert {:error, :not_found} = Mcp.revoke_authorization(Scope.for_user(user), family_id)
    assert {:ok, %Scope{}} = Mcp.resolve_access_token(access_token)
  end

  test "revoking a connection already gone is not found", %{user: user, connect: connect} do
    connect.(user)
    scope = Scope.for_user(user)
    [%{family_id: family_id}] = Mcp.list_authorizations(scope)

    assert :ok = Mcp.revoke_authorization(scope, family_id)
    assert {:error, :not_found} = Mcp.revoke_authorization(scope, family_id)
  end
end
