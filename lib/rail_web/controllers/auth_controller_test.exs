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

  describe "denied/2" do
    test "renders the denied page without a session", %{conn: conn} do
      conn = get(conn, ~p"/auth/denied")

      assert html_response(conn, 200) =~ "Rail is invite only"
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
