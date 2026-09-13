defmodule RailWeb.Settings.UsersLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup %{conn: conn} do
    id = System.unique_integer([:positive])

    assert {:ok, %User{} = admin_user} =
             Users.register_oauth_user(%{
               github_id: "admin_gh_#{id}",
               login: "admin_user_#{id}",
               name: "Admin User #{id}",
               email: "admin_#{id}@example.com",
               avatar_url: "https://example.com/avatar_#{id}.png",
               admin: true
             })

    admin_conn = log_in_user(conn, admin_user)

    assert {:ok, %User{} = regular_user} =
             Users.register_oauth_user(%{
               github_id: "regular_gh_#{id}",
               login: "regular_user_#{id}",
               name: "Regular User #{id}",
               email: "regular_#{id}@example.com",
               avatar_url: nil,
               admin: false
             })

    regular_conn = log_in_user(conn, regular_user)

    %{
      conn: conn,
      admin_conn: admin_conn,
      admin_user: admin_user,
      regular_conn: regular_conn,
      regular_user: regular_user
    }
  end

  test "redirects unauthenticated user to /auth/github", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/github"}}} = live(conn, ~p"/settings/users")
  end

  test "redirects non-admin user to /", %{regular_conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/users")
  end

  test "renders user list with avatars, roles, and linear connection", %{
    admin_conn: conn,
    admin_user: admin_user,
    regular_user: regular_user
  } do
    assert {:ok, view, _html} = live(conn, ~p"/settings/users")

    assert has_element?(view, "#users-settings")
    assert has_element?(view, "#users-title", "Users")
    assert has_element?(view, "#user-row-#{admin_user.id}")
    assert has_element?(view, "#user-row-#{regular_user.id}")

    # Check avatar image for admin and placeholder for regular user
    assert has_element?(view, "#user-avatar-#{admin_user.id}")
    assert has_element?(view, "#user-placeholder-#{regular_user.id}")

    # Check role badges
    assert has_element?(view, "#user-role-badge-#{admin_user.id}", "Admin")
    assert has_element?(view, "#user-role-badge-#{regular_user.id}", "User")

    # Check linear badge
    assert has_element?(view, "#user-linear-badge-#{regular_user.id}", "Linear: Not Linked")
  end

  test "promotes a regular user to admin and demotes them back", %{
    admin_conn: conn,
    regular_user: regular_user
  } do
    assert {:ok, view, _html} = live(conn, ~p"/settings/users")

    # Promote regular user
    view
    |> element("#toggle-admin-button-#{regular_user.id}")
    |> render_click()

    assert has_element?(view, "#user-role-badge-#{regular_user.id}", "Admin")
    assert has_element?(view, "#toggle-admin-button-#{regular_user.id}", "Revoke Admin")

    # Demote back
    view
    |> element("#toggle-admin-button-#{regular_user.id}")
    |> render_click()

    assert has_element?(view, "#user-role-badge-#{regular_user.id}", "User")
    assert has_element?(view, "#toggle-admin-button-#{regular_user.id}", "Make Admin")
  end

  test "cannot revoke admin from sole administrator", %{
    admin_conn: conn,
    admin_user: admin_user
  } do
    assert {:ok, view, _html} = live(conn, ~p"/settings/users")

    view
    |> element("#toggle-admin-button-#{admin_user.id}")
    |> render_click()

    assert has_element?(
             view,
             "#users-error-text",
             "Cannot revoke admin permissions from the sole administrator."
           )

    # Dismiss error
    view |> element("#clear-users-error-button") |> render_click()
    refute has_element?(view, "#users-error-banner")
  end

  test "ignores toggle_admin for non-existent user", %{admin_conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/users")

    render_click(view, "toggle_admin", %{"user_id" => "usr_nonexistent"})
    refute has_element?(view, "#users-error-banner")
  end

  test "renders Linear Linked fallback and initials fallback", %{conn: conn} do
    id = System.unique_integer([:positive])

    assert {:ok, %User{} = user} =
             Users.register_oauth_user(%{
               github_id: "fallback_gh_#{id}",
               login: "login_#{id}",
               name: "Name #{id}",
               email: "fallback_#{id}@example.com",
               admin: true
             })

    # Add linear_user_id without linear_name and clear name/login
    {:ok, %User{id: updated_user_id} = updated_user} =
      Rail.Repo.update(Ecto.Changeset.change(user, linear_user_id: "lin_#{id}", linear_name: nil, name: nil, login: ""))

    user_conn = log_in_user(conn, updated_user)

    assert {:ok, view, _html} = live(user_conn, ~p"/settings/users")
    assert has_element?(view, "#user-linear-badge-#{updated_user_id}", "Linear: Linked")
    assert has_element?(view, "#user-placeholder-#{updated_user_id}", "U")
  end

  test "handles authorization and generic errors on toggle_admin", %{
    admin_conn: conn,
    regular_user: regular_user
  } do
    assert {:ok, view, _html} = live(conn, ~p"/settings/users")

    expect(Users, :update_user, fn _scope, _user, _attrs ->
      {:error, :not_authorized}
    end)

    view |> element("#toggle-admin-button-#{regular_user.id}") |> render_click()

    assert has_element?(
             view,
             "#users-error-text",
             "You are not authorized to modify user permissions."
           )

    expect(Users, :update_user, fn _scope, _user, _attrs ->
      {:error, :db_error}
    end)

    view |> element("#toggle-admin-button-#{regular_user.id}") |> render_click()
    assert has_element?(view, "#users-error-text", "Failed to update user permissions.")
  end

  test "handles list_users error on mount", %{admin_conn: conn} do
    stub(Users, :list_users, fn _scope ->
      {:error, :network_timeout}
    end)

    assert {:ok, view, _html} = live(conn, ~p"/settings/users")
    assert has_element?(view, "#users-settings")
  end
end
