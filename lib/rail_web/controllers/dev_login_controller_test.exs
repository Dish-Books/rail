defmodule RailWeb.DevLoginControllerTest do
  use RailWeb.ConnCase, async: false
  use Mimic

  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, RailWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})
      |> fetch_flash()

    %{conn: conn}
  end

  describe "GET /dev/login" do
    test "creates a new admin user when not found and redirects to root", %{conn: conn} do
      conn = get(conn, ~p"/dev/login")

      assert redirected_to(conn) == ~p"/"
      assert token = get_session(conn, :user_token)

      assert {%User{email: "qa-admin@rail.local", admin: true}, _inserted_at} =
               Users.get_user_by_session_token(token)
    end

    test "logs in existing user and redirects to root", %{conn: conn} do
      assert {:ok, %User{id: existing_id}} =
               Users.register_oauth_user(%{
                 github_id: "qa_admin_existing_id",
                 login: "existing-qa",
                 name: "Existing Admin",
                 email: "qa-admin@rail.local",
                 admin: true
               })

      conn = get(conn, ~p"/dev/login")

      assert redirected_to(conn) == ~p"/"
      assert token = get_session(conn, :user_token)
      assert {%User{id: ^existing_id}, _inserted_at} = Users.get_user_by_session_token(token)
    end

    test "creates specified email when given in path parameter", %{conn: conn} do
      conn = get(conn, ~p"/dev/login/tester@rail.local")

      assert redirected_to(conn) == ~p"/"
      assert token = get_session(conn, :user_token)

      assert {%User{email: "tester@rail.local", admin: true}, _inserted_at} =
               Users.get_user_by_session_token(token)
    end

    test "redirects to return_to destination when specified in query params", %{conn: conn} do
      conn = get(conn, ~p"/dev/login?return_to=/issues")

      assert redirected_to(conn) == "/issues"
      assert token = get_session(conn, :user_token)

      assert {%User{email: "qa-admin@rail.local"}, _inserted_at} =
               Users.get_user_by_session_token(token)
    end

    test "redirects to return_to with email in path", %{conn: conn} do
      conn = get(conn, ~p"/dev/login/custom@rail.local?return_to=/cli-accounts")

      assert redirected_to(conn) == "/cli-accounts"
      assert token = get_session(conn, :user_token)

      assert {%User{email: "custom@rail.local"}, _inserted_at} =
               Users.get_user_by_session_token(token)
    end

    test "handles registration error with internal server error", %{conn: conn} do
      expect(Users, :get_user, fn [email: _email] -> {:error, :not_found} end)
      expect(Users, :register_oauth_user, fn _attrs -> {:error, :failed_registration} end)

      conn = get(conn, ~p"/dev/login/error-user@rail.local")

      assert response(conn, 500) =~ "Failed to sign in dev user"
    end
  end
end
