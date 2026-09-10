defmodule RailWeb.SettingsRedirectControllerTest do
  use RailWeb.ConnCase, async: true

  test "GET /settings unauthenticated redirects to /auth/github", %{conn: conn} do
    conn = get(conn, ~p"/settings")
    assert redirected_to(conn) == ~p"/auth/github"
  end

  test "GET /settings authenticated redirects to /settings/connected-accounts", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)
    conn = get(authed_conn, ~p"/settings")
    assert redirected_to(conn) == ~p"/settings/connected-accounts"
  end
end
