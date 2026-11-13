defmodule Rail.Mcp.Actions.ExchangeCodeTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.OauthAccessToken
  alias Rail.Mcp.Schemas.OauthAuthorizationCode
  alias Rail.Mcp.Schemas.OauthRefreshToken
  alias Rail.Scope
  alias Rail.Users

  setup do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "ex_#{id}",
        login: "ex_#{id}",
        name: "Ex #{id}",
        email: "ex_#{id}@example.com"
      })

    {:ok, client, nil} = Mcp.register_dynamic_client(%{"redirect_uris" => ["http://localhost/callback"]})
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    {:ok, %{redirect_url: url}} =
      Mcp.authorize(Scope.for_user(user), %{
        "client_id" => client.client_id,
        "redirect_uri" => "http://localhost:5000/callback",
        "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
        "code_challenge_method" => "S256"
      })

    params = %{
      "grant_type" => "authorization_code",
      "code" => URI.decode_query(URI.parse(url).query)["code"],
      "redirect_uri" => "http://localhost:5000/callback",
      "code_verifier" => verifier
    }

    Phoenix.PubSub.subscribe(Rail.PubSub, "mcp_authorizations")
    %{user: user, client: client, params: params}
  end

  test "exchanges a code once for a token pair, and says so", %{user: %{id: user_id}, client: client, params: params} do
    assert {:ok,
            %{
              access_token: "rail.at." <> _access,
              refresh_token: "rail.rt." <> _refresh,
              token_type: "Bearer",
              expires_in: 3600,
              scope: "mcp"
            }} = Mcp.exchange_code(client, Map.put(params, "resource", RailWeb.Endpoint.url() <> "/mcp"))

    assert_receive {:mcp_authorizations_changed, ^user_id}

    assert [%OauthAuthorizationCode{consumed_at: %DateTime{}}] =
             Repo.all(where(OauthAuthorizationCode, user_id: ^user_id))
  end

  test "a consumed code is refused and revokes every token of its family", %{
    user: %{id: user_id},
    client: client,
    params: params
  } do
    assert {:ok, %{access_token: access_token}} = Mcp.exchange_code(client, params)
    assert_receive {:mcp_authorizations_changed, ^user_id}

    assert {:error, :invalid_grant} = Mcp.exchange_code(client, %{params | "code_verifier" => "replayer's"})
    assert_receive {:mcp_authorizations_changed, ^user_id}

    assert [%OauthAccessToken{revoked_at: %DateTime{}}] = Repo.all(where(OauthAccessToken, user_id: ^user_id))
    assert [%OauthRefreshToken{revoked_at: %DateTime{}}] = Repo.all(where(OauthRefreshToken, user_id: ^user_id))
    assert {:error, :revoked} = Mcp.resolve_access_token(access_token)
  end

  test "a wrong verifier, another client or another redirect URI is refused, and the code stays usable", %{
    client: client,
    params: params
  } do
    {:ok, other_client, nil} = Mcp.register_dynamic_client(%{"redirect_uris" => ["http://localhost/callback"]})

    assert {:error, :invalid_grant} = Mcp.exchange_code(client, %{params | "code_verifier" => "wrong"})
    assert {:error, :invalid_grant} = Mcp.exchange_code(client, Map.delete(params, "code_verifier"))
    assert {:error, :invalid_grant} = Mcp.exchange_code(other_client, params)

    assert {:error, :invalid_grant} =
             Mcp.exchange_code(client, %{params | "redirect_uri" => "http://localhost:5000/other"})

    assert {:ok, %{access_token: _access_token}} = Mcp.exchange_code(client, params)
  end

  test "an expired code is refused", %{client: client, params: params} do
    Repo.update_all(OauthAuthorizationCode, set: [expires_at: DateTime.shift(DateTime.utc_now(), second: -1)])
    assert {:error, :invalid_grant} = Mcp.exchange_code(client, params)
  end

  test "a code that is not one, or whose verifier part is wrong, is refused", %{client: client, params: params} do
    ["rail", "ac", selector, _verifier] = String.split(params["code"], ".")

    for code <- [nil, "garbage", "rail.zz.#{selector}.abc", "rail.ac.#{selector}.!!", "rail.ac.#{selector}.abcd"] do
      assert {:error, :invalid_grant} = Mcp.exchange_code(client, %{params | "code" => code})
    end
  end

  test "refuses another grant type or another resource", %{client: client, params: params} do
    assert {:error, :unsupported_grant_type} = Mcp.exchange_code(client, %{params | "grant_type" => "password"})

    assert {:error, :invalid_target} =
             Mcp.exchange_code(client, Map.put(params, "resource", "https://elsewhere.example/mcp"))
  end
end
