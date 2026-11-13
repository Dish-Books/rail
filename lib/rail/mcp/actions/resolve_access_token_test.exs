defmodule Rail.Mcp.Actions.ResolveAccessTokenTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.OauthAccessToken
  alias Rail.Scope
  alias Rail.Users

  setup do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "rs_#{id}",
        login: "rs_#{id}",
        name: "Rs #{id}",
        email: "rs_#{id}@example.com"
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

    {:ok, %{access_token: access_token}} =
      Mcp.exchange_code(client, %{
        "grant_type" => "authorization_code",
        "code" => URI.decode_query(URI.parse(url).query)["code"],
        "redirect_uri" => "http://localhost/callback",
        "code_verifier" => verifier
      })

    Phoenix.PubSub.subscribe(Rail.PubSub, "mcp_authorizations")
    %{user: user, access_token: access_token}
  end

  test "resolves to its user's scope, writing last used on first use and not again within the minute", %{
    user: %{id: user_id},
    access_token: access_token
  } do
    assert {:ok, %Scope{user: %{id: ^user_id}, system: false}} = Mcp.resolve_access_token(access_token)
    assert_receive {:mcp_authorizations_changed, ^user_id}

    assert [%OauthAccessToken{last_used_at: %DateTime{} = first_use}] =
             Repo.all(where(OauthAccessToken, user_id: ^user_id))

    assert {:ok, %Scope{}} = Mcp.resolve_access_token(access_token)
    refute_receive {:mcp_authorizations_changed, ^user_id}
    assert [%OauthAccessToken{last_used_at: ^first_use}] = Repo.all(where(OauthAccessToken, user_id: ^user_id))

    Repo.update_all(OauthAccessToken, set: [last_used_at: DateTime.shift(DateTime.utc_now(), minute: -2)])
    assert {:ok, %Scope{}} = Mcp.resolve_access_token(access_token)
    assert_receive {:mcp_authorizations_changed, ^user_id}
  end

  test "an expired token, an unknown one, or a run token does not resolve", %{access_token: access_token} do
    ["rail", "at", selector, _verifier] = String.split(access_token, ".")
    {run_token, _hash} = Mcp.issue_run_token()

    for token <- ["rail.at.#{selector}.abcd", "rail.at.unknown.abcd", run_token, "rail.at.#{selector}.!!"] do
      assert {:error, :invalid_token} = Mcp.resolve_access_token(token)
    end

    Repo.update_all(OauthAccessToken, set: [expires_at: DateTime.shift(DateTime.utc_now(), second: -1)])
    assert {:error, :expired} = Mcp.resolve_access_token(access_token)
  end
end
