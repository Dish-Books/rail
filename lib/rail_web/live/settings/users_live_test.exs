defmodule RailWeb.Settings.UsersLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.Invite
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
      admin_scope: Scope.for_user(admin_user),
      regular_conn: regular_conn,
      regular_user: regular_user
    }
  end

  test "redirects an unauthenticated user to the sign-in page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/settings/users")
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

  test "cannot toggle admin on yourself", %{admin_conn: conn, admin_user: admin_user} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/users")

    refute has_element?(view, "#toggle-admin-button-#{admin_user.id}")

    render_click(view, "toggle_admin", %{"user_id" => admin_user.id})

    assert has_element?(
             view,
             "#users-error-text",
             "You cannot change your own admin permissions."
           )

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
      Repo.update(Ecto.Changeset.change(user, linear_user_id: "lin_#{id}", linear_name: nil, name: nil, login: ""))

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

  test "invites an email and lists it as pending", %{admin_conn: conn, admin_user: admin_user} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/users")

    assert has_element?(view, "#invites-empty")

    view
    |> form("#invite-form", %{"email" => "invited@example.com", "admin" => "on"})
    |> render_submit()

    assert %Invite{} = invite = Repo.get_by(Invite, email: "invited@example.com")
    assert invite.admin
    assert invite.invited_by_id == admin_user.id

    assert has_element?(view, "#invite-email-#{invite.id}", "invited@example.com")
    assert has_element?(view, "#invite-status-#{invite.id}", "Pending")
    assert has_element?(view, "#invite-admin-badge-#{invite.id}")
    refute has_element?(view, "#invites-empty")
  end

  test "revokes a pending invite", %{admin_conn: conn, admin_scope: scope} do
    assert {:ok, %Invite{id: invite_id}} = Users.invite_user(scope, %{email: "revokeme@example.com"})

    assert {:ok, view, _html} = live(conn, ~p"/settings/users")
    assert has_element?(view, "#invite-row-#{invite_id}")

    view |> element("#revoke-invite-button-#{invite_id}") |> render_click()

    refute has_element?(view, "#invite-row-#{invite_id}")
    assert Repo.get(Invite, invite_id) == nil
  end

  test "an accepted invite cannot be revoked from the list", %{admin_conn: conn, admin_scope: scope} do
    assert {:ok, %Invite{id: invite_id} = invite} = Users.invite_user(scope, %{email: "accepted@example.com"})
    assert {:ok, _updated} = invite |> Invite.changeset(%{accepted_at: DateTime.utc_now()}) |> Repo.update()

    assert {:ok, view, _html} = live(conn, ~p"/settings/users")

    assert has_element?(view, "#invite-status-#{invite_id}", "Accepted")
    refute has_element?(view, "#revoke-invite-button-#{invite_id}")

    render_click(view, "revoke_invite", %{"invite_id" => invite_id})
    assert has_element?(view, "#users-error-text", "That invite has already been accepted.")
  end

  test "surfaces a bad email address", %{admin_conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/users")

    view |> form("#invite-form", %{"email" => "not-an-email"}) |> render_submit()

    assert has_element?(view, "#users-error-text", "must be a valid email address")
  end

  test "keeps the typed invite in the form while the admin types", %{admin_conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/users")

    view |> form("#invite-form", %{"email" => "typing@example.com", "admin" => "on"}) |> render_change()

    assert has_element?(view, "#invite-email-input[value='typing@example.com']")
    assert has_element?(view, "#invite-admin-checkbox[checked]")
  end

  test "surfaces invite and revoke failures", %{admin_conn: conn, admin_scope: scope} do
    assert {:ok, %Invite{id: invite_id}} = Users.invite_user(scope, %{email: "failure@example.com"})

    assert {:ok, view, _html} = live(conn, ~p"/settings/users")

    expect(Users, :invite_user, fn _scope, _attrs -> {:error, :not_authorized} end)
    view |> form("#invite-form", %{"email" => "nope@example.com"}) |> render_submit()
    assert has_element?(view, "#users-error-text", "You are not authorized to invite users.")

    expect(Users, :invite_user, fn _scope, _attrs -> {:error, :already_accepted} end)
    view |> form("#invite-form", %{"email" => "nope@example.com"}) |> render_submit()
    assert has_element?(view, "#users-error-text", "That email has already signed up.")

    expect(Users, :invite_user, fn _scope, _attrs -> {:error, :db_error} end)
    view |> form("#invite-form", %{"email" => "nope@example.com"}) |> render_submit()
    assert has_element?(view, "#users-error-text", "Failed to send the invite.")

    # A changeset that failed on something other than the address has no email error
    # to quote back.
    expect(Users, :invite_user, fn _scope, _attrs ->
      {:error, Ecto.Changeset.add_error(Invite.changeset(%Invite{}, %{email: "ok@example.com"}), :admin, "is bad")}
    end)

    view |> form("#invite-form", %{"email" => "nope@example.com"}) |> render_submit()
    assert has_element?(view, "#users-error-text", "Failed to send the invite.")

    expect(Users, :revoke_invite, fn _scope, _id -> {:error, :not_authorized} end)
    view |> element("#revoke-invite-button-#{invite_id}") |> render_click()
    assert has_element?(view, "#users-error-text", "You are not authorized to revoke invites.")

    expect(Users, :revoke_invite, fn _scope, _id -> {:error, :db_error} end)
    view |> element("#revoke-invite-button-#{invite_id}") |> render_click()
    assert has_element?(view, "#users-error-text", "Failed to revoke the invite.")
  end

  test "handles list_invites error on mount", %{admin_conn: conn} do
    stub(Users, :list_invites, fn _scope -> {:error, :network_timeout} end)

    assert {:ok, view, _html} = live(conn, ~p"/settings/users")
    assert has_element?(view, "#invites-empty")
  end
end
