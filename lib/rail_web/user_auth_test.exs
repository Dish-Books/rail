defmodule RailWeb.UserAuthTest do
  use RailWeb.ConnCase, async: true

  alias Phoenix.LiveView
  alias Phoenix.Socket.Broadcast
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User
  alias RailWeb.UserAuth

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, RailWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})

    id = System.unique_integer([:positive])

    assert {:ok, %User{id: user_id} = user} =
             Users.register_oauth_user(%{
               github_id: "auth_test_gh_#{id}",
               login: "auth_user_#{id}",
               name: "Auth User #{id}",
               email: "auth_user_#{id}@example.com"
             })

    %{user: user, user_id: user_id, conn: conn}
  end

  describe "log_in_user/3" do
    test "stores user token in session and redirects to root", %{conn: conn, user: user} do
      conn = UserAuth.log_in_user(conn, user)
      assert token = get_session(conn, :user_token)
      assert get_session(conn, :live_socket_id) == "users_sessions:#{Base.url_encode64(token)}"
      assert redirected_to(conn) == ~p"/"
      assert Users.get_user_by_session_token(token)
    end

    test "clears previous session data on login", %{conn: conn, user: user} do
      conn =
        conn
        |> put_session(:to_be_cleared, "value")
        |> UserAuth.log_in_user(user)

      refute get_session(conn, :to_be_cleared)
    end

    test "preserves session when re-authenticating the same user", %{conn: conn, user: user} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> put_session(:keep_me, "preserved")
        |> UserAuth.log_in_user(user)

      assert get_session(conn, :keep_me) == "preserved"
    end

    test "clears session when re-authenticating a different user", %{conn: conn, user: user} do
      other_user = %User{id: "usr_different_user"}

      conn =
        conn
        |> assign(:current_scope, Scope.for_user(other_user))
        |> put_session(:drop_me, "lost")
        |> UserAuth.log_in_user(user)

      refute get_session(conn, :drop_me)
    end

    test "redirects to user_return_to if set", %{conn: conn, user: user} do
      conn =
        conn
        |> put_session(:user_return_to, "/custom/path")
        |> UserAuth.log_in_user(user)

      assert redirected_to(conn) == "/custom/path"
    end

    test "revokes the token the session was holding", %{conn: conn, user: user} do
      previous_token = Users.generate_user_session_token(user)

      conn =
        conn
        |> put_session(:user_token, previous_token)
        |> UserAuth.log_in_user(user)

      assert get_session(conn, :user_token) != previous_token
      refute Users.get_user_by_session_token(previous_token)
    end
  end

  describe "log_out_user/1" do
    test "erases the session and revokes the token", %{conn: conn, user: user} do
      user_token = Users.generate_user_session_token(user)

      conn =
        conn
        |> put_session(:user_token, user_token)
        |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(user_token)}")
        |> UserAuth.log_out_user()

      assert redirected_to(conn) == ~p"/sign-in"
      refute get_session(conn, :user_token)
      refute Users.get_user_by_session_token(user_token)
    end

    test "broadcasts to live_socket_id on logout", %{conn: conn, user: user} do
      user_token = Users.generate_user_session_token(user)
      live_socket_id = "users_sessions:#{Base.url_encode64(user_token)}"
      RailWeb.Endpoint.subscribe(live_socket_id)

      conn
      |> put_session(:user_token, user_token)
      |> put_session(:live_socket_id, live_socket_id)
      |> UserAuth.log_out_user()

      assert_receive %Broadcast{event: "disconnect", topic: ^live_socket_id}
    end
  end

  describe "fetch_current_user/2" do
    test "authenticates user from session", %{conn: conn, user: user, user_id: user_id} do
      user_token = Users.generate_user_session_token(user)

      conn =
        conn
        |> put_session(:user_token, user_token)
        |> UserAuth.fetch_current_user([])

      assert %Scope{user: %User{id: ^user_id}} = conn.assigns.current_scope
    end

    test "does not authenticate from a cookie", %{conn: conn, user: user} do
      user_token = Users.generate_user_session_token(user)

      conn =
        conn
        |> put_req_cookie("_rail_web_user_remember_me", user_token)
        |> UserAuth.fetch_current_user([])

      assert is_nil(conn.assigns.current_scope)
    end

    test "reissues token if older than reissue age", %{conn: conn, user: user} do
      {token, user_token} = Rail.Users.Schemas.UserToken.build_session_token(user)

      eight_days_ago = DateTime.shift(DateTime.utc_now(), day: -8)

      Repo.insert!(%{user_token | inserted_at: eight_days_ago})

      conn =
        conn
        |> put_session(:user_token, token)
        |> UserAuth.fetch_current_user([])

      new_token = get_session(conn, :user_token)
      assert byte_size(new_token) == 32
      refute new_token == token
    end

    test "assigns nil user scope when token is invalid or missing", %{conn: conn} do
      conn = UserAuth.fetch_current_user(conn, [])
      assert is_nil(conn.assigns.current_scope)
    end
  end

  describe "require_authenticated_user/2" do
    test "passes through when user is authenticated", %{conn: conn, user: user} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> UserAuth.require_authenticated_user([])

      refute conn.halted
    end

    test "halts and redirects to the sign-in page for a GET request, saving the path", %{conn: conn} do
      conn =
        %{conn | method: "GET", path_info: ["protected", "page"]}
        |> assign(:current_scope, Scope.for_user(nil))
        |> UserAuth.require_authenticated_user([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/sign-in"
      assert get_session(conn, :user_return_to) == "/protected/page"
    end

    test "halts and redirects for non-GET request without saving path", %{conn: conn} do
      conn =
        %{conn | method: "POST", path_info: ["protected", "action"]}
        |> assign(:current_scope, Scope.for_user(nil))
        |> UserAuth.require_authenticated_user([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/sign-in"
      refute get_session(conn, :user_return_to)
    end
  end

  describe "require_admin_user/2" do
    test "passes through when scope is admin", %{conn: conn, user: user} do
      admin_user = %{user | admin: true}

      conn =
        conn
        |> assign(:current_scope, Scope.for_user(admin_user))
        |> UserAuth.require_admin_user([])

      refute conn.halted
    end

    test "halts and redirects to root when scope is not admin", %{conn: conn, user: user} do
      non_admin = %{user | admin: false}

      conn =
        conn
        |> assign(:current_scope, Scope.for_user(non_admin))
        |> UserAuth.require_admin_user([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/"
    end

    test "call/2 dispatches to require_admin_user", %{conn: conn, user: user} do
      admin_user = %{user | admin: true}

      conn =
        conn
        |> assign(:current_scope, Scope.for_user(admin_user))
        |> UserAuth.call(:require_admin_user)

      refute conn.halted
    end

    test "call/2 dispatches to require_authenticated_user", %{conn: conn, user: user} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> UserAuth.call(:require_authenticated_user)

      refute conn.halted
    end
  end

  describe "disconnect_sessions/1" do
    test "broadcasts disconnect for each token" do
      token = :crypto.strong_rand_bytes(32)
      topic = "users_sessions:#{Base.url_encode64(token)}"
      RailWeb.Endpoint.subscribe(topic)

      UserAuth.disconnect_sessions([%{token: token}])

      assert_receive %Broadcast{event: "disconnect", topic: ^topic}
    end
  end

  describe "on_mount hooks" do
    test "mount_current_scope assigns current_scope from session", %{user: user, user_id: user_id} do
      user_token = Users.generate_user_session_token(user)
      session = %{"user_token" => user_token}
      socket = %LiveView.Socket{endpoint: RailWeb.Endpoint}

      assert {:cont, %LiveView.Socket{assigns: %{current_scope: %Scope{user: %User{id: ^user_id}}}}} =
               UserAuth.on_mount(:mount_current_scope, %{}, session, socket)
    end

    test "require_authenticated halts when unauthenticated" do
      session = %{}
      socket = %LiveView.Socket{endpoint: RailWeb.Endpoint}

      assert {:halt, %LiveView.Socket{assigns: %{current_scope: nil}}} =
               UserAuth.on_mount(:require_authenticated, %{}, session, socket)
    end

    test "require_authenticated continues when user is authenticated", %{user: user} do
      user_token = Users.generate_user_session_token(user)
      session = %{"user_token" => user_token}
      socket = %LiveView.Socket{endpoint: RailWeb.Endpoint}

      assert {:cont, _socket} = UserAuth.on_mount(:require_authenticated, %{}, session, socket)
    end

    test "require_admin continues when user is admin", %{user: user} do
      assert {:ok, admin_user} =
               Users.update_user(Scope.for_system(), user, %{admin: true})

      user_token = Users.generate_user_session_token(admin_user)
      session = %{"user_token" => user_token}
      socket = %LiveView.Socket{endpoint: RailWeb.Endpoint}

      assert {:cont, _socket} = UserAuth.on_mount(:require_admin, %{}, session, socket)
    end

    test "require_admin halts when user is not admin", %{user: user} do
      assert {:ok, non_admin_user} = Users.update_user(Scope.for_system(), user, %{admin: false})
      user_token = Users.generate_user_session_token(non_admin_user)
      session = %{"user_token" => user_token}
      socket = %LiveView.Socket{endpoint: RailWeb.Endpoint}

      assert {:halt, _halted_socket} = UserAuth.on_mount(:require_admin, %{}, session, socket)
    end
  end
end
