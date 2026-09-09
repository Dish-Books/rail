defmodule RailWeb.Settings.ConnectedAccountsLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Repo
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup %{conn: conn} do
    id = System.unique_integer([:positive])

    assert {:ok, %User{id: user_id} = user} =
             Users.register_oauth_user(%{
               github_id: "live_gh_#{id}",
               login: "live_user_#{id}",
               name: "Live User #{id}",
               email: "live_#{id}@example.com",
               avatar_url: "https://example.com/avatar_#{id}.png"
             })

    user_token = Users.generate_user_session_token(user)

    authed_conn =
      conn
      |> Map.replace!(:secret_key_base, RailWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})
      |> put_session(:user_token, user_token)

    %{conn: conn, authed_conn: authed_conn, user: user, user_id: user_id}
  end

  test "redirects unauthenticated user to /auth/github", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/github"}}} =
             live(conn, ~p"/settings/connected-accounts")
  end

  test "renders GitHub section and disconnected Linear section when not linked", %{
    authed_conn: conn,
    user: user
  } do
    assert {:ok, view, html} = live(conn, ~p"/settings/connected-accounts")

    assert html =~ "Connected Accounts"
    assert html =~ "Manage third-party services connected to your account"
    assert html =~ "GitHub"
    assert html =~ user.login
    assert html =~ user.name
    assert html =~ user.email
    assert has_element?(view, "#github-avatar")
    assert html =~ "Linear is not connected."
    assert has_element?(view, "#connect-linear-button")
    refute has_element?(view, "#disconnect-linear-button")
  end

  test "renders GitHub placeholder avatar when avatar_url is missing", %{conn: conn} do
    id = System.unique_integer([:positive])

    assert {:ok, %User{} = user_no_avatar} =
             Users.register_oauth_user(%{
               github_id: "no_avatar_gh_#{id}",
               login: "no_avatar_#{id}",
               email: "no_avatar_#{id}@example.com",
               avatar_url: nil
             })

    token = Users.generate_user_session_token(user_no_avatar)

    authed_conn =
      conn
      |> Map.replace!(:secret_key_base, RailWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})
      |> put_session(:user_token, token)

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/connected-accounts")
    assert has_element?(view, "#github-avatar-placeholder")
  end

  test "renders connected Linear section when user is linked", %{
    authed_conn: conn,
    user: user
  } do
    assert {:ok, %User{}} =
             Users.link_linear(user, %{
               linear_user_id: "lin_123",
               linear_name: "Jane Doe Linear",
               linear_access_token: "lin_at",
               linear_refresh_token: "lin_rt",
               expires_in: 3600
             })

    assert {:ok, view, html} = live(conn, ~p"/settings/connected-accounts")

    assert html =~ "Connected as"
    assert html =~ "Jane Doe Linear"
    assert has_element?(view, "#disconnect-linear-button")
    refute has_element?(view, "#connect-linear-button")
  end

  test "disconnects Linear when Disconnect button is clicked", %{
    authed_conn: conn,
    user: user,
    user_id: user_id
  } do
    assert {:ok, %User{}} =
             Users.link_linear(user, %{
               linear_user_id: "lin_disconnect_id",
               linear_name: "Disconnect User",
               linear_access_token: "lin_at_disconnect",
               linear_refresh_token: "lin_rt_disconnect",
               expires_in: 3600
             })

    assert {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
    assert has_element?(view, "#disconnect-linear-button")

    rendered =
      view
      |> element("#disconnect-linear-button")
      |> render_click()

    assert rendered =~ "Linear is not connected."
    assert has_element?(view, "#connect-linear-button")
    refute has_element?(view, "#disconnect-linear-button")

    reloaded = Repo.get!(User, user_id)
    assert is_nil(reloaded.linear_access_token)
    assert is_nil(reloaded.linear_user_id)
  end

  test "supports unlink event hook directly", %{
    authed_conn: conn,
    user: user,
    user_id: user_id
  } do
    assert {:ok, %User{}} =
             Users.link_linear(user, %{
               linear_access_token: "lin_at_unlink_hook",
               linear_refresh_token: "lin_rt_unlink_hook",
               expires_in: 3600
             })

    assert {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")

    rendered = render_hook(view, "unlink", %{})

    assert rendered =~ "Linear is not connected."

    reloaded = Repo.get!(User, user_id)
    assert is_nil(reloaded.linear_access_token)
  end

  test "handles disconnect error gracefully when user cannot be unlinked", %{
    authed_conn: conn,
    user: user
  } do
    assert {:ok, %User{}} =
             Users.link_linear(user, %{
               linear_access_token: "lin_at_err_test",
               linear_refresh_token: "lin_rt_err_test",
               expires_in: 3600
             })

    assert {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")

    Repo.delete!(user)

    rendered = render_click(element(view, "#disconnect-linear-button"))
    assert rendered =~ "Connected as"
  end
end
