defmodule Rail.Mcp.Actions.RefreshTokenTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.OauthAccessToken
  alias Rail.Mcp.Schemas.OauthRefreshToken
  alias Rail.Scope
  alias Rail.Users

  setup do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "rf_#{id}",
        login: "rf_#{id}",
        name: "Rf #{id}",
        email: "rf_#{id}@example.com"
      })

    {:ok, client, nil} = Mcp.register_dynamic_client(%{"redirect_uris" => ["http://localhost/callback"]})
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    {:ok, %{redirect_url: url}} =
      Mcp.authorize(Scope.for_user(user), %{
        "client_id" => client.client_id,
        "redirect_uri" => "http://localhost/callback",
        "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
        "code_challenge_method" => "S256"
      })

    {:ok, tokens} =
      Mcp.exchange_code(client, %{
        "grant_type" => "authorization_code",
        "code" => URI.decode_query(URI.parse(url).query)["code"],
        "redirect_uri" => "http://localhost/callback",
        "code_verifier" => verifier
      })

    Phoenix.PubSub.subscribe(Rail.PubSub, "mcp_authorizations")
    %{user: user, client: client, tokens: tokens}
  end

  test "rotates the pair within its family, retiring the old one", %{
    user: %{id: user_id},
    client: client,
    tokens: %{access_token: old_access, refresh_token: old_refresh}
  } do
    assert {:ok, %{access_token: new_access, refresh_token: new_refresh, token_type: "Bearer", scope: "mcp"}} =
             Mcp.refresh_token(client, %{"grant_type" => "refresh_token", "refresh_token" => old_refresh})

    assert_receive {:mcp_authorizations_changed, ^user_id}
    assert {:error, :revoked} = Mcp.resolve_access_token(old_access)
    assert {:ok, %Scope{user: %{id: ^user_id}}} = Mcp.resolve_access_token(new_access)
    assert new_refresh != old_refresh

    assert [family_id] =
             Repo.all(from(t in OauthAccessToken, where: t.user_id == ^user_id, distinct: true, select: t.family_id))

    assert 2 = Repo.aggregate(where(OauthRefreshToken, family_id: ^family_id), :count)
  end

  test "reusing a rotated refresh token revokes the whole family", %{
    user: %{id: user_id},
    client: client,
    tokens: %{refresh_token: old_refresh}
  } do
    {:ok, %{access_token: new_access, refresh_token: new_refresh}} =
      Mcp.refresh_token(client, %{"grant_type" => "refresh_token", "refresh_token" => old_refresh})

    assert_receive {:mcp_authorizations_changed, ^user_id}

    assert {:error, :invalid_grant} =
             Mcp.refresh_token(client, %{"grant_type" => "refresh_token", "refresh_token" => old_refresh})

    assert_receive {:mcp_authorizations_changed, ^user_id}
    assert {:error, :revoked} = Mcp.resolve_access_token(new_access)

    assert {:error, :invalid_grant} =
             Mcp.refresh_token(client, %{"grant_type" => "refresh_token", "refresh_token" => new_refresh})
  end

  test "refuses an expired refresh token, another client's, or one that is not a token", %{
    client: client,
    tokens: %{refresh_token: refresh}
  } do
    {:ok, other_client, nil} = Mcp.register_dynamic_client(%{"redirect_uris" => ["http://localhost/callback"]})

    assert {:error, :invalid_grant} =
             Mcp.refresh_token(other_client, %{"grant_type" => "refresh_token", "refresh_token" => refresh})

    assert {:error, :invalid_grant} = Mcp.refresh_token(client, %{"grant_type" => "refresh_token"})

    Repo.update_all(OauthRefreshToken, set: [expires_at: DateTime.shift(DateTime.utc_now(), second: -1)])

    assert {:error, :invalid_grant} =
             Mcp.refresh_token(client, %{"grant_type" => "refresh_token", "refresh_token" => refresh})
  end

  test "refuses another grant type", %{client: client, tokens: %{refresh_token: refresh}} do
    assert {:error, :unsupported_grant_type} = Mcp.refresh_token(client, %{"refresh_token" => refresh})
  end
end
