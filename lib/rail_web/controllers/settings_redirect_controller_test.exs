defmodule RailWeb.SettingsRedirectControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Users

  test "GET /settings unauthenticated redirects to /auth/github", %{conn: conn} do
    conn = get(conn, ~p"/settings")
    assert redirected_to(conn) == ~p"/auth/github"
  end

  test "GET /settings authenticated redirects to /settings/connected-accounts", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_settings_redirect_1",
        login: "settings_redirect_user_1",
        email: "settings_redirect_user_1@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    conn = get(authed_conn, ~p"/settings")
    assert redirected_to(conn) == ~p"/settings/connected-accounts"
  end
end
