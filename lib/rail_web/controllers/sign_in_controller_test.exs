defmodule RailWeb.SignInControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Clients.CloudflareAccess
  alias Rail.Users.Schemas.User

  setup_all do
    %{key: JOSE.JWK.generate_key({:rsa, 2048})}
  end

  setup %{key: key} do
    id = System.unique_integer([:positive])
    {_kty, public} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    Req.Test.stub(CloudflareAccess, &Req.Test.json(&1, %{"keys" => [public]}))

    {:ok, admin} =
      Users.register_oauth_user(%{github_id: "sign_in_admin_#{id}", login: "sign-in-admin-#{id}", email: "a-#{id}@x.io"})

    {:ok, admin} = Users.update_user(Scope.for_system(), admin, %{admin: true})

    claims = %{
      "email" => "luis-#{id}@dishbooks.com",
      "iss" => "https://team.cloudflareaccess.com",
      "aud" => ["rail-aud"],
      "exp" => System.os_time(:second) + 300
    }

    {_jws, token} = key |> JOSE.JWT.sign(%{"alg" => "RS256"}, claims) |> JOSE.JWS.compact()
    %{admin: admin, token: token, email: claims["email"]}
  end

  test "offers a way in rather than starting the provider handshake", %{conn: conn} do
    html = conn |> get(~p"/sign-in") |> html_response(200)

    assert html =~ "Sign in with GitHub"
    assert html =~ ~s(href="/auth/github")
  end

  # Signing out lands here, and a signed-in session arriving here is nothing to do.
  test "sends a signed-in user on to the app", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{github_id: "sign_in_gh", login: "sign_in_user", email: "sign_in@example.com"})

    conn = conn |> log_in_user(user) |> get(~p"/sign-in")

    assert redirected_to(conn) == ~p"/"
  end

  describe "under Cloudflare Access" do
    setup do
      stub(Rail, :cloudflare_access, fn -> %{team_domain: "team.cloudflareaccess.com", aud: "rail-aud"} end)
      :ok
    end

    test "signs an invited person in from Access's token, without GitHub, and sends them where they were going", %{
      conn: conn,
      admin: admin,
      token: token,
      email: email
    } do
      {:ok, _invite} = Users.invite_user(Scope.for_user(admin), %{email: email})

      conn =
        conn
        |> init_test_session(%{user_return_to: "/issues"})
        |> put_req_header("cf-access-jwt-assertion", token)
        |> get(~p"/sign-in")

      assert redirected_to(conn) == "/issues"

      assert {%User{email: ^email, github_id: nil}, _inserted_at} =
               Users.get_user_by_session_token(get_session(conn, :user_token))
    end

    test "turns away an address with no invite on a page naming it", %{conn: conn, token: token, email: email} do
      conn = conn |> put_req_header("cf-access-jwt-assertion", token) |> get(~p"/sign-in")

      assert redirected_to(conn) == ~p"/auth/denied"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "#{email} has not been invited to Rail."
      refute get_session(conn, :user_token)
    end

    test "turns away a token Access did not sign", %{conn: conn} do
      conn = conn |> put_req_header("cf-access-jwt-assertion", "forged") |> get(~p"/sign-in")

      assert redirected_to(conn) == ~p"/auth/denied"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "could not vouch for who you are"
      refute get_session(conn, :user_token)
    end

    test "says so when the team's keys cannot be read", %{conn: conn, token: token} do
      Req.Test.stub(CloudflareAccess, &(&1 |> Plug.Conn.put_status(500) |> Req.Test.json(%{})))

      conn = conn |> put_req_header("cf-access-jwt-assertion", token) |> get(~p"/sign-in")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Could not sign in through Cloudflare Access."
    end

    test "offers GitHub when the request carries no token", %{conn: conn} do
      assert conn |> get(~p"/sign-in") |> html_response(200) =~ "Sign in with GitHub"
    end
  end

  test "without Access set up, the same header signs nobody in", %{conn: conn, admin: admin, token: token, email: email} do
    {:ok, _invite} = Users.invite_user(Scope.for_user(admin), %{email: email})

    conn = conn |> put_req_header("cf-access-jwt-assertion", token) |> get(~p"/sign-in")

    assert html_response(conn, 200) =~ "Sign in with GitHub"
    refute get_session(conn, :user_token)
    assert {:error, :not_found} = Users.get_user(email: email)
  end
end
