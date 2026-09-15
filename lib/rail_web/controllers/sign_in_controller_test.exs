defmodule RailWeb.SignInControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Users

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
end
