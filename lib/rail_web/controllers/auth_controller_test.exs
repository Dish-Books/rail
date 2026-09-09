defmodule RailWeb.AuthControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Users
  alias Rail.Users.Schemas.User
  alias RailWeb.AuthController
  alias Ueberauth.Auth

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, RailWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})
      |> fetch_flash()

    %{conn: conn}
  end

  describe "request/2" do
    test "passes through request phase", %{conn: conn} do
      conn = AuthController.request(conn, %{"provider" => "github"})
      refute conn.halted
    end
  end

  describe "callback/2" do
    test "redirects to root on ueberauth failure", %{conn: conn} do
      conn =
        conn
        |> assign(:ueberauth_failure, %Ueberauth.Failure{})
        |> AuthController.callback(%{})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Failed to authenticate with GitHub."
      assert redirected_to(conn) == ~p"/"
    end

    test "registers user and logs in on successful authentication", %{conn: conn} do
      auth = %Auth{
        provider: :github,
        uid: "55555",
        info: %Auth.Info{
          nickname: "gh_controller_user",
          name: "Controller User",
          email: "controller_user@example.com",
          image: "https://example.com/avatar.png"
        },
        credentials: %Auth.Credentials{
          token: "gho_controller_token"
        }
      }

      conn =
        conn
        |> assign(:ueberauth_auth, auth)
        |> AuthController.callback(%{})

      assert token = get_session(conn, :user_token)
      assert byte_size(token) == 32
      assert redirected_to(conn) == ~p"/"
      assert {%User{github_id: "55555"}, _inserted_at} = Users.get_user_by_session_token(token)
    end

    test "handles registration error gracefully", %{conn: conn} do
      auth = %Auth{
        provider: :github,
        uid: nil,
        info: %Auth.Info{
          nickname: nil,
          email: nil
        }
      }

      conn =
        conn
        |> assign(:ueberauth_auth, auth)
        |> AuthController.callback(%{})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Could not sign in with GitHub."
      assert redirected_to(conn) == ~p"/"
    end

    test "handles missing auth/failure gracefully", %{conn: conn} do
      conn = AuthController.callback(conn, %{})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Authentication was cancelled or failed."
      assert redirected_to(conn) == ~p"/"
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

      assert redirected_to(conn) == ~p"/"
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

      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
    end
  end
end
