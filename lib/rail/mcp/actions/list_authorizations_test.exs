defmodule Rail.Mcp.Actions.ListAuthorizationsTest do
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
        github_id: "la_#{id}",
        login: "la_#{id}",
        name: "La #{id}",
        email: "la_#{id}@example.com"
      })

    {:ok, other} =
      Users.register_oauth_user(%{
        github_id: "lb_#{id}",
        login: "lb_#{id}",
        name: "Lb #{id}",
        email: "lb_#{id}@example.com"
      })

    {:ok, code_client, nil} =
      Mcp.register_dynamic_client(%{"client_name" => "Claude Code", "redirect_uris" => ["http://localhost/callback"]})

    {:ok, web_client, nil} =
      Mcp.register_dynamic_client(%{
        "client_name" => "Claude",
        "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"]
      })

    connect = fn person, client ->
      verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      [redirect_uri] = client.redirect_uris

      {:ok, %{redirect_url: url}} =
        Mcp.authorize(Scope.for_user(person), %{
          "client_id" => client.client_id,
          "redirect_uri" => redirect_uri,
          "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
          "code_challenge_method" => "S256"
        })

      {:ok, tokens} =
        Mcp.exchange_code(client, %{
          "grant_type" => "authorization_code",
          "code" => URI.decode_query(URI.parse(url).query)["code"],
          "redirect_uri" => redirect_uri,
          "code_verifier" => verifier
        })

      tokens
    end

    %{user: user, other: other, code_client: code_client, web_client: web_client, connect: connect}
  end

  test "lists one row per connection, newest first, with where each returns to", %{
    user: user,
    other: other,
    code_client: code_client,
    web_client: web_client,
    connect: connect
  } do
    %{refresh_token: web_refresh} = connect.(user, web_client)
    connect.(user, code_client)
    connect.(other, code_client)

    # The older connection rotates, which keeps its connected time and adds no row.
    Repo.update_all(where(OauthAccessToken, oauth_client_id: ^web_client.id),
      set: [inserted_at: DateTime.shift(DateTime.utc_now(), hour: -1)]
    )

    {:ok, _rotated} = Mcp.refresh_token(web_client, %{"grant_type" => "refresh_token", "refresh_token" => web_refresh})

    assert [
             %{client_name: "Claude Code", redirect_host: "localhost", family_id: code_family},
             %{
               client_name: "Claude",
               redirect_host: "claude.ai",
               family_id: web_family,
               connected_at: connected_at,
               last_used_at: last_used_at
             }
           ] = Mcp.list_authorizations(Scope.for_user(user))

    assert code_family != web_family
    assert DateTime.before?(connected_at, last_used_at)
    assert [%{client_name: "Claude Code"}] = Mcp.list_authorizations(Scope.for_user(other))
  end

  test "ties on time are broken by family", %{user: user, code_client: code_client, connect: connect} do
    connect.(user, code_client)
    connect.(user, code_client)
    Repo.update_all(OauthAccessToken, set: [inserted_at: DateTime.utc_now()])

    families = Repo.all(from(c in OauthAuthorizationCode, select: c.family_id, order_by: [desc: c.family_id]))
    assert ^families = Enum.map(Mcp.list_authorizations(Scope.for_user(user)), & &1.family_id)
  end

  test "last used is the newest use in the family once there is one", %{
    user: user,
    code_client: code_client,
    connect: connect
  } do
    %{access_token: access_token} = connect.(user, code_client)
    {:ok, _scope} = Mcp.resolve_access_token(access_token)
    [%OauthAccessToken{last_used_at: used_at}] = Repo.all(OauthAccessToken)

    assert [%{last_used_at: ^used_at}] = Mcp.list_authorizations(Scope.for_user(user))
  end

  test "leaves out a connection that was revoked or whose refresh token expired, and lists none at first", %{
    user: user,
    code_client: code_client,
    connect: connect
  } do
    assert [] = Mcp.list_authorizations(Scope.for_user(user))

    connect.(user, code_client)
    [%{family_id: family_id}] = Mcp.list_authorizations(Scope.for_user(user))
    :ok = Mcp.revoke_authorization(Scope.for_user(user), family_id)
    assert [] = Mcp.list_authorizations(Scope.for_user(user))

    connect.(user, code_client)
    Repo.update_all(OauthRefreshToken, set: [expires_at: DateTime.shift(DateTime.utc_now(), second: -1)])
    assert [] = Mcp.list_authorizations(Scope.for_user(user))
  end
end
