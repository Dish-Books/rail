defmodule RailWeb.LinearAuthControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup %{conn: conn} do
    id = System.unique_integer([:positive])

    assert {:ok, %User{id: user_id} = user} =
             Users.register_oauth_user(%{
               github_id: "linear_ctrl_gh_#{id}",
               login: "ctrl_user_#{id}",
               name: "Controller User #{id}",
               email: "ctrl_#{id}@example.com"
             })

    user_token = Users.generate_user_session_token(user)

    authed_conn =
      conn
      |> Map.replace!(:secret_key_base, RailWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})
      |> put_session(:user_token, user_token)

    %{conn: conn, authed_conn: authed_conn, user: user, user_id: user_id}
  end

  describe "GET /auth/linear" do
    test "redirects to Linear OAuth authorize URL and stores state in session", %{
      authed_conn: conn
    } do
      conn = get(conn, ~p"/auth/linear")

      assert redirect_url = redirected_to(conn, 302)
      assert String.starts_with?(redirect_url, "https://linear.app/oauth/authorize?")
      assert String.contains?(redirect_url, "response_type=code")
      assert String.contains?(redirect_url, "actor=user")
      assert String.contains?(redirect_url, "scope=read%2Cwrite%2Cissues%3Acreate%2Ccomments%3Acreate")
      assert String.contains?(redirect_url, "client_id=test_linear_client_id")
      assert get_session(conn, :linear_oauth_state)
    end

    test "redirects unauthenticated user to GitHub login", %{conn: conn} do
      conn = get(conn, ~p"/auth/linear")

      assert redirected_to(conn) == ~p"/auth/github"
    end
  end

  describe "GET /auth/linear/callback" do
    test "links Linear credentials on successful code exchange and viewer fetch", %{
      authed_conn: conn,
      user_id: user_id
    } do
      Req.Test.expect(Rail.Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert URI.decode_query(body)["grant_type"] == "authorization_code"

        Req.Test.json(conn, %{
          "access_token" => "lin_callback_at",
          "token_type" => "Bearer",
          "expires_in" => 3600,
          "refresh_token" => "lin_callback_rt",
          "scope" => ["read", "write", "issues:create", "comments:create"]
        })
      end)

      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "viewer" => %{"id" => "lin_viewer_id", "name" => "Linear Callback User", "email" => "user@example.com"}
          }
        })
      end)

      conn =
        conn
        |> put_session(:linear_oauth_state, "state123")
        |> get(~p"/auth/linear/callback", %{"code" => "good_code", "state" => "state123"})

      assert redirected_to(conn) == ~p"/settings/connected-accounts"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Connected Linear account successfully"
      refute get_session(conn, :linear_oauth_state)

      reloaded = Repo.get!(User, user_id)
      assert reloaded.linear_access_token == "lin_callback_at"
      assert reloaded.linear_refresh_token == "lin_callback_rt"
      assert reloaded.linear_user_id == "lin_viewer_id"
      assert reloaded.linear_name == "Linear Callback User"
      assert reloaded.linear_token_expires_at
    end

    test "handles code exchange failure", %{authed_conn: conn} do
      Req.Test.expect(Rail.Linear, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "invalid_grant", "error_description" => "Invalid authorization code"})
      end)

      conn =
        conn
        |> put_session(:linear_oauth_state, "state_exchange_fail")
        |> get(~p"/auth/linear/callback", %{"code" => "bad_code", "state" => "state_exchange_fail"})

      assert redirected_to(conn) == ~p"/settings/connected-accounts"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Failed to exchange Linear authorization code"
    end

    test "handles viewer fetch failure", %{authed_conn: conn} do
      Req.Test.expect(Rail.Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert URI.decode_query(body)["grant_type"] == "authorization_code"

        Req.Test.json(conn, %{
          "access_token" => "mock_linear_access_token",
          "token_type" => "Bearer",
          "expires_in" => 3600,
          "refresh_token" => "mock_linear_refresh_token",
          "scope" => ["read", "write", "issues:create", "comments:create"]
        })
      end)

      Req.Test.expect(Rail.Linear, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"errors" => [%{"message" => "Not authenticated"}]})
      end)

      conn =
        conn
        |> put_session(:linear_oauth_state, "state_viewer_fail")
        |> get(~p"/auth/linear/callback", %{"code" => "code_viewer_fail", "state" => "state_viewer_fail"})

      assert redirected_to(conn) == ~p"/settings/connected-accounts"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Failed to fetch Linear user profile"
    end

    test "handles OAuth error parameter when access is denied", %{authed_conn: conn} do
      conn = get(conn, ~p"/auth/linear/callback", %{"error" => "access_denied"})

      assert redirected_to(conn) == ~p"/settings/connected-accounts"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Linear authentication was denied or cancelled"
    end

    test "handles missing code and error gracefully", %{authed_conn: conn} do
      conn = get(conn, ~p"/auth/linear/callback", %{})

      assert redirected_to(conn) == ~p"/settings/connected-accounts"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Linear authentication failed"
    end

    test "handles linking failure when the user cannot be updated", %{authed_conn: conn} do
      Req.Test.expect(Rail.Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert URI.decode_query(body)["grant_type"] == "authorization_code"

        Req.Test.json(conn, %{
          "access_token" => "mock_linear_access_token",
          "token_type" => "Bearer",
          "expires_in" => 3600,
          "refresh_token" => "mock_linear_refresh_token",
          "scope" => ["read", "write", "issues:create", "comments:create"]
        })
      end)

      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{"viewer" => %{"id" => "lin_usr_123", "name" => "Linear Test User", "email" => "user@example.com"}}
        })
      end)

      expect(Users, :update_user, fn _scope, _user, _attrs -> {:error, :db_error} end)

      conn =
        conn
        |> put_session(:linear_oauth_state, "state_link_fail")
        |> get(~p"/auth/linear/callback", %{"code" => "code_link_fail", "state" => "state_link_fail"})

      assert redirected_to(conn) == ~p"/settings/connected-accounts"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Failed to link Linear account"
    end

    test "rejects a callback whose state does not match the session", %{authed_conn: conn} do
      conn =
        conn
        |> put_session(:linear_oauth_state, "real_state")
        |> get(~p"/auth/linear/callback", %{"code" => "forged_code", "state" => "attacker_state"})

      assert redirected_to(conn) == ~p"/settings/connected-accounts"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Linear authentication failed"
      refute get_session(conn, :linear_oauth_state)
    end

    test "rejects a callback when the session holds no state", %{authed_conn: conn} do
      conn = get(conn, ~p"/auth/linear/callback", %{"code" => "forged_code", "state" => "attacker_state"})

      assert redirected_to(conn) == ~p"/settings/connected-accounts"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Linear authentication failed"
    end

    test "rejects a callback with a code but no state", %{authed_conn: conn} do
      conn =
        conn
        |> put_session(:linear_oauth_state, "real_state")
        |> get(~p"/auth/linear/callback", %{"code" => "forged_code"})

      assert redirected_to(conn) == ~p"/settings/connected-accounts"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Linear authentication failed"
    end

    test "redirects unauthenticated user to GitHub login", %{conn: conn} do
      conn = get(conn, ~p"/auth/linear/callback", %{"code" => "any_code", "state" => "any_state"})

      assert redirected_to(conn) == ~p"/auth/github"
    end
  end

  describe "unlink routes" do
    test "GET /auth/linear/unlink disconnects Linear and redirects", %{
      authed_conn: conn,
      user: user,
      user_id: user_id
    } do
      assert {:ok, %User{}} =
               Users.update_user(Scope.for_system(), user, %{
                 linear_access_token: "unlink_at",
                 linear_refresh_token: "unlink_rt",
                 linear_user_id: "u_id",
                 linear_name: "U Name",
                 linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
               })

      conn = get(conn, ~p"/auth/linear/unlink")

      assert redirected_to(conn) == ~p"/settings/connected-accounts"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Disconnected Linear account"

      reloaded = Repo.get!(User, user_id)
      assert is_nil(reloaded.linear_access_token)
      assert is_nil(reloaded.linear_user_id)
    end

    test "POST /auth/linear/unlink disconnects Linear", %{
      authed_conn: conn,
      user: user,
      user_id: user_id
    } do
      assert {:ok, %User{}} =
               Users.update_user(Scope.for_system(), user, %{
                 linear_access_token: "unlink_post_at",
                 linear_refresh_token: "unlink_post_rt",
                 linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
               })

      conn = post(conn, ~p"/auth/linear/unlink")

      assert redirected_to(conn) == ~p"/settings/connected-accounts"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Disconnected Linear account"

      reloaded = Repo.get!(User, user_id)
      assert is_nil(reloaded.linear_access_token)
    end

    test "DELETE /auth/linear/unlink disconnects Linear", %{
      authed_conn: conn,
      user: user,
      user_id: user_id
    } do
      assert {:ok, %User{}} =
               Users.update_user(Scope.for_system(), user, %{
                 linear_access_token: "unlink_del_at",
                 linear_refresh_token: "unlink_del_rt",
                 linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
               })

      conn = delete(conn, ~p"/auth/linear/unlink")

      assert redirected_to(conn) == ~p"/settings/connected-accounts"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Disconnected Linear account"

      reloaded = Repo.get!(User, user_id)
      assert is_nil(reloaded.linear_access_token)
    end

    test "handles unlinking failure when user cannot be unlinked", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> fetch_flash()
        |> assign(:current_scope, nil)
        |> RailWeb.LinearAuthController.unlink(%{})

      assert redirected_to(conn) == ~p"/settings/connected-accounts"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not disconnect Linear account"
    end

    test "redirects unauthenticated user to GitHub login", %{conn: conn} do
      conn = delete(conn, ~p"/auth/linear/unlink")

      assert redirected_to(conn) == ~p"/auth/github"
    end
  end
end
