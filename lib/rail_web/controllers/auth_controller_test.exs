defmodule RailWeb.AuthControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.Invite
  alias Rail.Users.Schemas.User
  alias RailWeb.AuthController
  alias Ueberauth.Auth

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, RailWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})
      |> fetch_flash()

    # The admission rules only bite once the instance has an account; without one the
    # first sign-in bootstraps itself, which is not what most of these tests exercise.
    assert {:ok, %User{id: admin_id} = admin} =
             Users.register_oauth_user(%{
               github_id: "existing_admin_gh",
               login: "existing_admin",
               email: "existing_admin@example.com",
               admin: true
             })

    auth = %Auth{
      provider: :github,
      uid: "55555",
      info: %Auth.Info{
        nickname: "gh_controller_user",
        name: "Controller User",
        email: "controller@example.com",
        image: "https://example.com/avatar.png"
      },
      credentials: %Auth.Credentials{token: "gho_controller_token"}
    }

    %{conn: conn, admin: admin, admin_id: admin_id, auth: auth}
  end

  describe "request/2" do
    test "passes through request phase", %{conn: conn} do
      conn = AuthController.request(conn, %{"provider" => "github"})
      refute conn.halted
    end
  end

  describe "callback/2" do
    test "redirects to the denied page on ueberauth failure", %{conn: conn} do
      conn =
        conn
        |> assign(:ueberauth_failure, %Ueberauth.Failure{})
        |> AuthController.callback(%{})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Failed to authenticate with GitHub."
      assert redirected_to(conn) == ~p"/auth/denied"
    end

    test "turns away a GitHub account with no invite", %{conn: conn, auth: auth} do
      conn =
        conn
        |> assign(:ueberauth_auth, auth)
        |> AuthController.callback(%{})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "has not been invited"
      assert redirected_to(conn) == ~p"/auth/denied"
      refute get_session(conn, :user_token)
      assert {:error, :not_found} = Users.get_user(email: "controller@example.com")
    end

    test "turns away a GitHub account with no email", %{conn: conn, auth: auth} do
      conn =
        conn
        |> assign(:ueberauth_auth, put_in(auth.info.email, nil))
        |> AuthController.callback(%{})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "did not share an email address"
      assert redirected_to(conn) == ~p"/auth/denied"
    end

    test "registers and logs in an invited account", %{conn: conn, admin: admin, auth: auth} do
      assert {:ok, %Invite{} = invite} =
               Users.invite_user(Scope.for_user(admin), %{email: "controller@example.com", admin: false})

      conn =
        conn
        |> assign(:ueberauth_auth, auth)
        |> AuthController.callback(%{})

      assert token = get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      assert {%User{github_id: "55555", admin: false, id: user_id}, _inserted_at} =
               Users.get_user_by_session_token(token)

      assert %Invite{accepted_at: %DateTime{}, accepted_user_id: ^user_id} = Repo.get(Invite, invite.id)
    end

    test "an admin invite lands as an admin account", %{conn: conn, admin: admin, auth: auth} do
      assert {:ok, %Invite{}} =
               Users.invite_user(Scope.for_user(admin), %{email: "controller@example.com", admin: true})

      conn =
        conn
        |> assign(:ueberauth_auth, auth)
        |> AuthController.callback(%{})

      assert token = get_session(conn, :user_token)
      assert {%User{admin: true}, _inserted_at} = Users.get_user_by_session_token(token)
    end

    test "an existing user signs in without an invite", %{conn: conn, admin: admin, admin_id: admin_id, auth: auth} do
      auth = %{auth | uid: admin.github_id, info: %{auth.info | email: admin.email, nickname: admin.login}}

      conn =
        conn
        |> assign(:ueberauth_auth, auth)
        |> AuthController.callback(%{})

      assert token = get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
      assert {%User{id: ^admin_id}, _inserted_at} = Users.get_user_by_session_token(token)
    end

    test "a returning user who signs in with GitHub keeps the email Access knows them by", %{conn: conn, auth: auth} do
      assert {:ok, %User{id: user_id}} =
               Users.register_oauth_user(%{github_id: "77777", login: "luis", email: "luis@railai.dev"})

      auth = %{auth | uid: "77777", info: %{auth.info | email: "luis.ortega@gmail.com", nickname: "luis"}}

      conn =
        conn
        |> assign(:ueberauth_auth, auth)
        |> AuthController.callback(%{})

      assert {%User{id: ^user_id}, _inserted_at} = Users.get_user_by_session_token(get_session(conn, :user_token))
      assert {:ok, %User{id: ^user_id, email: "luis@railai.dev"}} = Users.get_user(id: user_id)
    end

    test "handles registration error gracefully", %{conn: conn, admin: admin, auth: auth} do
      assert {:ok, %Invite{}} = Users.invite_user(Scope.for_user(admin), %{email: "broken@example.com"})

      auth = %{auth | uid: nil, info: %{auth.info | nickname: nil, name: nil, email: "broken@example.com"}}

      conn =
        conn
        |> assign(:ueberauth_auth, auth)
        |> AuthController.callback(%{})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Could not sign in with GitHub."
      assert redirected_to(conn) == ~p"/auth/denied"
    end

    test "handles missing auth/failure gracefully", %{conn: conn} do
      conn = AuthController.callback(conn, %{})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Authentication was cancelled or failed."
      assert redirected_to(conn) == ~p"/auth/denied"
    end
  end

  describe "callback/2 while signed in" do
    setup %{auth: auth} do
      {:ok, tester} =
        Users.register_oauth_user(%{github_id: "gh_linking", login: "linking", email: "luis@dishbooks.com"})

      {:ok, tester} = Users.unlink_github(Scope.for_user(tester))
      %{tester: tester, auth: auth}
    end

    test "connects GitHub to the account instead of signing in, and returns to Connected accounts", %{
      conn: conn,
      tester: %User{id: tester_id} = tester,
      auth: auth
    } do
      conn =
        conn
        |> assign(:current_scope, Scope.for_user(tester))
        |> assign(:ueberauth_auth, auth)
        |> AuthController.callback(%{})

      assert redirected_to(conn) == ~p"/settings/connected-accounts"
      refute Phoenix.Flash.get(conn.assigns.flash, :github_error)
      refute get_session(conn, :user_token)

      assert {:ok, %User{id: ^tester_id, github_id: "55555", login: "gh_controller_user", email: "luis@dishbooks.com"}} =
               Users.get_user(id: tester_id)
    end

    test "refuses a GitHub account on another Rail account, naming both", %{conn: conn, tester: tester, auth: auth} do
      {:ok, _priya} =
        Users.register_oauth_user(%{github_id: "55555", login: "priyar", name: "Priya Raman", email: "priya@x.io"})

      conn =
        conn
        |> assign(:current_scope, Scope.for_user(tester))
        |> assign(:ueberauth_auth, auth)
        |> AuthController.callback(%{})

      assert redirected_to(conn) == ~p"/settings/connected-accounts"

      assert Phoenix.Flash.get(conn.assigns.flash, :github_error) ==
               "That GitHub account, priyar, is already connected to Priya Raman's Rail account. Nothing changed."

      assert %User{github_id: nil} = Repo.reload!(tester)
    end

    test "refuses a second GitHub account, and a profile it cannot save", %{conn: conn, tester: tester, auth: auth} do
      {:ok, linked} =
        Users.link_github(Scope.for_user(tester), %{auth | uid: "44444", info: %{auth.info | nickname: "first"}})

      conn =
        conn
        |> assign(:current_scope, Scope.for_user(linked))
        |> assign(:ueberauth_auth, auth)
        |> AuthController.callback(%{})

      assert Phoenix.Flash.get(conn.assigns.flash, :github_error) =~ "connected to GitHub as first. Disconnect it"

      {:ok, newcomer} = Users.register_oauth_user(%{github_id: "gh_newcomer", login: "newcomer", email: "new@x.io"})
      {:ok, newcomer} = Users.unlink_github(Scope.for_user(newcomer))

      conn =
        build_conn()
        |> init_test_session(%{})
        |> fetch_flash()
        |> assign(:current_scope, Scope.for_user(newcomer))
        |> assign(:ueberauth_auth, %{auth | uid: "66666", info: %{auth.info | nickname: nil, name: nil}})
        |> AuthController.callback(%{})

      assert Phoenix.Flash.get(conn.assigns.flash, :github_error) == "Could not connect GitHub. Nothing changed."
    end

    test "a cancelled or failed GitHub step leaves them signed in, on Connected accounts", %{conn: conn, tester: tester} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_user(tester))
        |> assign(:ueberauth_failure, %Ueberauth.Failure{})
        |> AuthController.callback(%{})

      assert redirected_to(conn) == ~p"/settings/connected-accounts"
      assert Phoenix.Flash.get(conn.assigns.flash, :github_error) == "GitHub did not finish connecting. Nothing changed."
    end
  end

  describe "denied/2" do
    test "renders the denied page without a session", %{conn: conn} do
      conn = get(conn, ~p"/auth/denied")

      assert html_response(conn, 200) =~ "Rail is invite only"

      assert [class] =
               conn |> html_response(200) |> Floki.parse_document!() |> Floki.attribute("#auth-denied", "class")

      assert "min-h-dvh" in String.split(class)
    end

    test "under Access, offers another address through Cloudflare's logout, or GitHub" do
      stub(Rail, :cloudflare_access, fn -> %{team_domain: "team.cloudflareaccess.com", aud: "rail-aud"} end)

      html =
        build_conn()
        |> init_test_session(%{"phoenix_flash" => %{"error" => "luis@gmail.com has not been invited to Rail."}})
        |> get(~p"/auth/denied")
        |> html_response(200)

      assert html =~ "luis@gmail.com has not been invited to Rail."
      assert html =~ "sign out of Cloudflare Access and use the address you were invited with"
      assert html =~ ~s(href="/cdn-cgi/access/logout")
      assert html =~ ~s(href="/auth/github")
      refute html =~ "auth-denied-retry"
    end

    test "under Access, says Rail could not reach Cloudflare rather than that the person is not invited" do
      stub(Rail, :cloudflare_access, fn -> %{team_domain: "team.cloudflareaccess.com", aud: "rail-aud"} end)

      html = build_conn() |> get(~p"/auth/denied?reason=unreachable") |> html_response(200)

      assert html =~ "Rail could not reach Cloudflare Access"
      assert ["/sign-in"] = html |> Floki.parse_document!() |> Floki.attribute("#auth-denied-try-again", "href")
      refute html =~ "Rail is invite only"
      refute html =~ "Ask an admin"
      refute html =~ "/cdn-cgi/access/logout"
      refute html =~ "/auth/github"
    end

    test "without Access, the unreachable reason changes nothing", %{conn: conn} do
      html = conn |> get(~p"/auth/denied?reason=unreachable") |> html_response(200)

      assert html =~ "An admin invites the email address on your GitHub account"
      assert ["/auth/github"] = html |> Floki.parse_document!() |> Floki.attribute("#auth-denied-retry", "href")
      refute html =~ "Rail could not reach Cloudflare Access"
      refute html =~ "auth-denied-try-again"
    end

    test "shows the reason the sign-in was refused" do
      # A fresh conn: the one from setup has already fetched an empty flash, and the
      # pipeline will not fetch it twice.
      conn =
        build_conn()
        |> init_test_session(%{"phoenix_flash" => %{"error" => "has not been invited"}})
        |> get(~p"/auth/denied")

      assert html_response(conn, 200) =~ "has not been invited"
    end
  end

  describe "delete/2 (logout)" do
    test "logs out user on DELETE /auth/logout", %{conn: conn} do
      assert {:ok, user} =
               Users.register_oauth_user(%{
                 github_id: "logout_test_gh",
                 login: "logout_user",
                 email: "logout@example.com"
               })

      token = Users.generate_user_session_token(user)

      conn =
        conn
        |> put_session(:user_token, token)
        |> delete(~p"/auth/logout")

      assert redirected_to(conn) == ~p"/sign-in"
      refute get_session(conn, :user_token)
    end

    test "logs out user on GET /auth/logout", %{conn: conn} do
      assert {:ok, user} =
               Users.register_oauth_user(%{
                 github_id: "logout_get_gh",
                 login: "logout_get_user",
                 email: "logoutget@example.com"
               })

      token = Users.generate_user_session_token(user)

      conn =
        conn
        |> put_session(:user_token, token)
        |> get(~p"/auth/logout")

      assert redirected_to(conn) == ~p"/sign-in"
      refute get_session(conn, :user_token)
    end
  end
end
