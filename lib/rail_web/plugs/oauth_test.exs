defmodule RailWeb.Plugs.OAuthTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Mcp
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users
  alias RailWeb.Plugs.OAuth

  setup do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "oap_#{id}",
        login: "oap_#{id}",
        name: "Oap",
        email: "oap_#{id}@example.com"
      })

    {:ok, client, nil} = Mcp.register_dynamic_client(%{"redirect_uris" => ["http://localhost/callback"]})

    connect = fn ->
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

      access_token
    end

    %{user: user, connect: connect}
  end

  test "assigns the person's scope for a live token", %{conn: conn, user: %{id: user_id}, connect: connect} do
    conn = conn |> put_req_header("authorization", "Bearer #{connect.()}") |> OAuth.call(OAuth.init([]))

    refute conn.halted
    assert %Scope{user: %{id: ^user_id}} = conn.assigns.current_scope
  end

  test "a revoked token gets a 401 naming the metadata, while the person's other connection still resolves", %{
    conn: conn,
    user: user,
    connect: connect
  } do
    revoked = connect.()
    kept = connect.()
    [_kept_family, %{family_id: family_id}] = Mcp.list_authorizations(Scope.for_user(user))
    :ok = Mcp.revoke_authorization(Scope.for_user(user), family_id)

    denied = conn |> put_req_header("authorization", "Bearer #{revoked}") |> OAuth.call(OAuth.init([]))
    metadata = RailWeb.Endpoint.url() <> "/.well-known/oauth-protected-resource/mcp"

    assert denied.halted

    assert %{"error" => "invalid_token", "error_description" => "the access token was revoked"} =
             json_response(denied, 401)

    assert [challenge] = get_resp_header(denied, "www-authenticate")
    assert challenge =~ ~s(resource_metadata="#{metadata}")

    refute (conn |> put_req_header("authorization", "Bearer #{kept}") |> OAuth.call(OAuth.init([]))).halted
  end

  test "no token, a bad one, an expired one or a run token gets a 401", %{conn: conn, connect: connect} do
    expired = connect.()
    Repo.update_all(Rail.Mcp.Schemas.OauthAccessToken, set: [expires_at: DateTime.shift(DateTime.utc_now(), second: -1)])
    {run_token, _hash} = Mcp.issue_run_token()

    for {header, description} <- [
          {nil, "no bearer token supplied"},
          {"Bearer ", "no bearer token supplied"},
          {"Bearer nonsense", "the access token is invalid"},
          {"Bearer #{run_token}", "the access token is invalid"},
          {"Bearer #{expired}", "the access token expired"}
        ] do
      conn = if header, do: put_req_header(conn, "authorization", header), else: conn

      assert %{"error_description" => ^description} =
               conn |> OAuth.call(OAuth.init([])) |> json_response(401)
    end
  end

  test "a run token at /mcp gets the person-facing 401", %{conn: conn} do
    stub(Mcp, :authenticate_run_token, fn _token -> flunk("/mcp must never accept a run token") end)

    assert [_challenge] =
             conn
             |> put_req_header("authorization", "Bearer run_token")
             |> put_req_header("content-type", "application/json")
             |> post(~p"/mcp", ~s({"jsonrpc":"2.0","id":1,"method":"tools/list"}))
             |> tap(&assert(&1.status == 401))
             |> get_resp_header("www-authenticate")
  end
end
