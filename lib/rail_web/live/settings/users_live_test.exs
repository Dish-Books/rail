defmodule RailWeb.Settings.UsersLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.Invite
  alias Rail.Users.Schemas.User

  setup %{conn: conn, project: project} do
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

    {:ok, regular_user} = Users.update_user(Scope.for_system(), regular_user, %{project_ids: [project.id]})
    regular_conn = log_in_user(conn, regular_user)

    {:ok, second_project} =
      Projects.create_project(Scope.for_system(), %{
        name: "Harbor API",
        github_repo: "harbor-labs/harbor-api",
        github_installation_id: 4_040,
        linear_team_key: "HAR",
        default_branch: "main",
        clone_path: "/tmp/repos/harbor-api"
      })

    {:ok, inactive_project} =
      Projects.create_project(Scope.for_system(), %{
        name: "Data pipelines",
        github_repo: "railai/pipelines",
        github_installation_id: 4_041,
        linear_team_key: "DAT",
        default_branch: "main",
        clone_path: "/tmp/repos/pipelines",
        active: false
      })

    %{
      conn: conn,
      admin_conn: admin_conn,
      admin_user: admin_user,
      admin_scope: Scope.for_user(admin_user),
      regular_conn: regular_conn,
      regular_user: regular_user,
      second_project: second_project,
      inactive_project: inactive_project
    }
  end

  test "redirects an unauthenticated user to the sign-in page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/settings/users")
  end

  test "redirects non-admin user to /", %{regular_conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/users")
  end

  test "lists each person with what they can access, their Linear account and role", %{
    admin_conn: conn,
    admin_user: admin_user,
    regular_user: regular_user,
    project: project
  } do
    {:ok, nobody} =
      Users.register_oauth_user(%{github_id: "nobody_gh", login: "nobody", name: "Taylor Brooks", email: "t@x.io"})

    assert {:ok, view, _html} = live(conn, ~p"/settings/users")

    assert has_element?(view, "#users-title", "Users")
    assert has_element?(view, "#users-subtitle", "the projects each user works on")
    assert has_element?(view, "#users-count", "Users · 3")
    assert has_element?(view, "#user-name-#{admin_user.id}", admin_user.name)
    assert has_element?(view, "#user-you-#{admin_user.id}", "You")
    refute has_element?(view, "#user-you-#{regular_user.id}")
    assert has_element?(view, "#user-login-#{regular_user.id}", "@#{regular_user.login} · #{regular_user.email}")

    assert has_element?(view, "#user-avatar-#{admin_user.id}")
    assert has_element?(view, "#user-placeholder-#{regular_user.id}", "RU")

    assert has_element?(view, "#user-projects-#{admin_user.id}", "All projects")
    assert has_element?(view, "#user-projects-#{regular_user.id}[title='#{project.name}']", project.name)
    assert has_element?(view, "#user-projects-#{nobody.id}", "No projects")

    assert has_element?(view, "#user-role-badge-#{admin_user.id}", "Admin")
    assert has_element?(view, "#user-role-badge-#{regular_user.id}", "User")
    assert has_element?(view, "#user-linear-badge-#{regular_user.id}", "Linear: Not Linked")
    refute has_element?(view, "#user-sheet")
  end

  test "clicking a person opens their sheet with their projects ticked, and each tick saves", %{
    admin_conn: conn,
    regular_user: regular_user,
    project: %{id: project_id} = project,
    second_project: %{id: second_id} = second_project,
    inactive_project: inactive_project
  } do
    assert {:ok, view, _html} = live(conn, ~p"/settings/users")

    view |> element("#user-row-#{regular_user.id}") |> render_click()

    assert has_element?(view, "#user-row-#{regular_user.id}[aria-selected='true']")
    assert has_element?(view, "#user-sheet[aria-label='#{regular_user.name}']")
    assert has_element?(view, "#user-sheet", "@#{regular_user.login} · #{regular_user.email}")
    assert has_element?(view, "#user-sheet", "Every project, and the settings screens.")
    refute has_element?(view, "#user-sheet-admin[checked]")
    assert has_element?(view, "#user-sheet-project-#{project.id}[checked]")
    refute has_element?(view, "#user-sheet-project-#{second_project.id}[checked]")
    assert has_element?(view, "#user-sheet-row-#{second_project.id}", "harbor-labs/harbor-api")
    assert has_element?(view, "#user-sheet-row-#{second_project.id} [data-qa='project-badge']", "HAR")
    assert has_element?(view, "#user-sheet-row-#{inactive_project.id}.opacity-60", "Inactive")

    view
    |> form("#user-access-form", %{"user" => %{"project_ids" => [project.id, second_project.id]}})
    |> render_change()

    assert %User{project_ids: [^project_id, ^second_id]} = Repo.get!(User, regular_user.id)
    assert has_element?(view, "#user-sheet-project-#{second_project.id}[checked]")
    assert has_element?(view, "#user-projects-#{regular_user.id}", "Harbor API, #{project.name}")

    view |> form("#user-access-form", %{"user" => %{"project_ids" => [second_project.id]}}) |> render_change()

    assert %User{project_ids: [^second_id]} = Repo.get!(User, regular_user.id)
    refute has_element?(view, "#user-sheet-project-#{project.id}[checked]")
  end

  test "unticking every project leaves the person with none", %{
    admin_conn: conn,
    regular_user: regular_user
  } do
    assert {:ok, view, _html} = live(conn, ~p"/settings/users")
    view |> element("#user-row-#{regular_user.id}") |> render_click()

    render_change(view, "update_access", %{"user_id" => regular_user.id, "user" => %{"project_ids" => [""]}})

    assert %User{project_ids: []} = Repo.get!(User, regular_user.id)
    assert has_element?(view, "#user-projects-#{regular_user.id}", "No projects")
  end

  test "ticking Admin shows every project ticked and disabled, and unticking it restores the grants", %{
    admin_conn: conn,
    regular_user: regular_user,
    project: %{id: granted} = project,
    second_project: second_project
  } do
    assert {:ok, view, _html} = live(conn, ~p"/settings/users")
    view |> element("#user-row-#{regular_user.id}") |> render_click()

    view
    |> form("#user-access-form", %{"user" => %{"admin" => "true", "project_ids" => [project.id]}})
    |> render_change()

    assert %User{admin: true, project_ids: [^granted]} = Repo.get!(User, regular_user.id)
    assert has_element?(view, "#user-sheet-admin[checked]")
    assert has_element?(view, "#user-sheet-project-#{second_project.id}[checked][disabled]")
    assert has_element?(view, "#user-projects-#{regular_user.id}", "All projects")
    assert has_element?(view, "#user-role-badge-#{regular_user.id}", "Admin")

    # Disabled boxes are not sent, so only the flag comes back.
    render_change(view, "update_access", %{"user_id" => regular_user.id, "user" => %{"admin" => "false"}})

    assert %User{admin: false, project_ids: [^granted]} = Repo.get!(User, regular_user.id)
    assert has_element?(view, "#user-sheet-project-#{project.id}[checked]")
    refute has_element?(view, "#user-sheet-project-#{second_project.id}[checked]")
  end

  test "your own Admin box is disabled, and a crafted change to it does nothing", %{
    admin_conn: conn,
    admin_user: admin_user
  } do
    assert {:ok, view, _html} = live(conn, ~p"/settings/users")
    view |> element("#user-row-#{admin_user.id}") |> render_click()

    assert has_element?(view, "#user-sheet-admin[checked][disabled]")

    render_change(view, "update_access", %{"user_id" => admin_user.id, "user" => %{"admin" => "false"}})

    assert %User{admin: true} = Repo.get!(User, admin_user.id)
  end

  test "a change for someone not on the list does nothing", %{admin_conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/users")

    render_change(view, "update_access", %{"user_id" => "usr_nonexistent", "user" => %{"admin" => "true"}})
    render_click(view, "open_user", %{"user_id" => "usr_nonexistent"})

    refute has_element?(view, "#users-error-banner")
    refute has_element?(view, "#user-sheet")
  end

  test "the sheet closes from its button and on Escape, and the page behind stays usable", %{
    admin_conn: conn,
    regular_user: regular_user,
    admin_user: admin_user
  } do
    assert {:ok, view, _html} = live(conn, ~p"/settings/users")

    view |> element("#user-row-#{regular_user.id}") |> render_click()
    view |> element("#user-sheet-close") |> render_click()
    refute has_element?(view, "#user-sheet")

    view |> element("#user-row-#{regular_user.id}") |> render_keydown(%{"key" => "Enter"})
    assert has_element?(view, "#user-sheet[aria-label='#{regular_user.name}']")

    view |> element("#user-row-#{admin_user.id}") |> render_click()
    assert has_element?(view, "#user-sheet[aria-label='#{admin_user.name}']")
    refute has_element?(view, "#user-row-#{regular_user.id}[aria-selected='true']")

    view |> element("#user-sheet") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, "#user-sheet")
  end

  test "a change saved in another tab shows on the open page", %{
    admin_conn: conn,
    admin_scope: scope,
    regular_user: regular_user,
    second_project: second_project
  } do
    assert {:ok, view, _html} = live(conn, ~p"/settings/users")
    view |> element("#user-row-#{regular_user.id}") |> render_click()

    {:ok, _user} = Users.update_user(scope, regular_user, %{project_ids: [second_project.id]})

    assert has_element?(view, "#user-sheet-project-#{second_project.id}[checked]")
    assert has_element?(view, "#user-projects-#{regular_user.id}", "Harbor API")

    {:ok, %Invite{id: invite_id}} = Users.invite_user(scope, %{email: "elsewhere@example.com"})

    assert has_element?(view, "#invite-row-#{invite_id}")
  end

  test "a failed save says why", %{admin_conn: conn, regular_user: regular_user, project: project} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/users")
    view |> element("#user-row-#{regular_user.id}") |> render_click()

    expect(Users, :update_user, fn _scope, _user, _attrs -> {:error, :not_authorized} end)
    view |> form("#user-access-form", %{"user" => %{"project_ids" => [project.id]}}) |> render_change()
    assert has_element?(view, "#users-error-text", "You are not authorized to modify user permissions.")

    expect(Users, :update_user, fn _scope, _user, _attrs -> {:error, :db_error} end)
    view |> form("#user-access-form", %{"user" => %{"project_ids" => [project.id]}}) |> render_change()
    assert has_element?(view, "#users-error-text", "Failed to update user permissions.")

    view |> element("#clear-users-error-button") |> render_click()
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

  test "handles list_users error on mount", %{admin_conn: conn} do
    stub(Users, :list_users, fn _scope ->
      {:error, :network_timeout}
    end)

    assert {:ok, view, _html} = live(conn, ~p"/settings/users")
    assert has_element?(view, "#users-settings")
  end

  test "Invite opens the same sheet and sends an invite carrying its projects", %{
    admin_conn: conn,
    admin_user: %{id: inviter_id} = admin_user,
    project: %{id: granted} = project,
    second_project: second_project
  } do
    assert {:ok, view, _html} = live(conn, ~p"/settings/users")

    assert has_element?(view, "#invites-empty")
    view |> element("#invite-button") |> render_click()
    assert has_element?(view, "#invite-sheet[aria-label='Invite']")
    refute has_element?(view, "#invite-sheet-project-#{project.id}[checked]")

    view
    |> form("#invite-form", %{"email" => "invited@example.com", "project_ids" => [project.id]})
    |> render_submit()

    assert %Invite{admin: false, project_ids: [^granted], invited_by_id: ^inviter_id} =
             invite = Repo.get_by(Invite, email: "invited@example.com")

    refute has_element?(view, "#invite-sheet")

    assert has_element?(view, "#invite-email-#{invite.id}", "invited@example.com")
    assert has_element?(view, "#invite-row-#{invite.id}", "Invited by #{admin_user.name}")
    assert has_element?(view, "#invite-projects-#{invite.id}", project.name)
    refute has_element?(view, "#invite-projects-#{invite.id}", second_project.name)
    assert has_element?(view, "#invite-status-#{invite.id}", "Pending")
    assert has_element?(view, "#revoke-invite-button-#{invite.id}", "Revoke")
    refute has_element?(view, "#invites-empty")
  end

  test "an admin invite gets every project", %{admin_conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/users")
    view |> element("#invite-button") |> render_click()

    view |> form("#invite-form", %{"email" => "boss@example.com", "admin" => "on"}) |> render_submit()

    assert %Invite{admin: true} = invite = Repo.get_by(Invite, email: "boss@example.com")
    assert has_element?(view, "#invite-projects-#{invite.id}", "All projects")
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
    view |> element("#invite-button") |> render_click()

    view |> form("#invite-form", %{"email" => "not-an-email"}) |> render_submit()

    assert has_element?(view, "#users-error-text", "must be a valid email address")
    assert has_element?(view, "#invite-sheet")
  end

  test "keeps the typed invite in the sheet while the admin types, and Admin ticks every project", %{
    admin_conn: conn,
    project: project,
    second_project: second_project
  } do
    assert {:ok, view, _html} = live(conn, ~p"/settings/users")
    view |> element("#invite-button") |> render_click()

    view |> form("#invite-form", %{"email" => "typing@example.com", "project_ids" => [project.id]}) |> render_change()

    assert has_element?(view, "#invite-email-input[value='typing@example.com']")
    assert has_element?(view, "#invite-sheet-project-#{project.id}[checked]")

    view |> form("#invite-form", %{"email" => "typing@example.com", "admin" => "on"}) |> render_change()

    assert has_element?(view, "#invite-admin-checkbox[checked]")
    assert has_element?(view, "#invite-sheet-project-#{second_project.id}[checked][disabled]")

    # Disabled boxes are not sent, so unticking Admin sends only the blank.
    render_change(view, "invite_form_change", %{"email" => "typing@example.com", "project_ids" => [""]})

    assert has_element?(view, "#invite-sheet-project-#{project.id}[checked]")
    refute has_element?(view, "#invite-sheet-project-#{second_project.id}[checked]")

    view |> element("#invite-sheet-close") |> render_click()
    refute has_element?(view, "#invite-sheet")
  end

  test "surfaces invite and revoke failures", %{admin_conn: conn, admin_scope: scope} do
    assert {:ok, %Invite{id: invite_id}} = Users.invite_user(scope, %{email: "failure@example.com"})

    assert {:ok, view, _html} = live(conn, ~p"/settings/users")
    view |> element("#invite-button") |> render_click()

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
