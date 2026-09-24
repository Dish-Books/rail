defmodule RailWeb.Settings.ProjectsLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
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

    admin_token = Users.generate_user_session_token(admin_user)

    admin_conn =
      conn
      |> Map.replace!(:secret_key_base, RailWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})
      |> put_session(:user_token, admin_token)

    assert {:ok, %User{} = regular_user} =
             Users.register_oauth_user(%{
               github_id: "regular_gh_#{id}",
               login: "regular_user_#{id}",
               name: "Regular User #{id}",
               email: "regular_#{id}@example.com",
               avatar_url: "https://example.com/avatar_regular_#{id}.png",
               admin: false
             })

    regular_token = Users.generate_user_session_token(regular_user)

    regular_conn =
      conn
      |> Map.replace!(:secret_key_base, RailWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})
      |> put_session(:user_token, regular_token)

    %{
      conn: conn,
      admin_conn: admin_conn,
      admin_user: admin_user,
      regular_conn: regular_conn,
      regular_user: regular_user
    }
  end

  test "redirects an unauthenticated user to the sign-in page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/settings/projects")
  end

  test "redirects non-admin user to /", %{regular_conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/projects")
  end

  test "lists registered projects with details", %{admin_conn: conn, admin_user: admin} do
    scope = Scope.for_user(admin)
    id = System.unique_integer([:positive])

    assert {:ok, %Project{id: p1_id}} =
             Projects.create_project(scope, %{
               name: "Active App",
               github_repo: "example/active-#{id}",
               github_installation_id: 111,
               linear_team_key: "ACT",
               default_branch: "main",
               clone_path: "/tmp/active",
               active: true
             })

    assert {:ok, %Project{id: p2_id}} =
             Projects.create_project(scope, %{
               name: "Inactive App",
               github_repo: "example/inactive-#{id}",
               github_installation_id: 222,
               linear_team_key: "INACT",
               default_branch: "main",
               clone_path: "/tmp/inactive",
               active: false
             })

    assert {:ok, view, html} = live(conn, ~p"/settings/projects")
    refute has_element?(view, "#empty-projects-message")

    assert has_element?(view, "#project-item-#{p1_id}")
    assert has_element?(view, "#project-item-#{p2_id}")

    assert html =~ "Active App"
    assert html =~ "Inactive App"
    assert html =~ "example/active-#{id}"
    assert html =~ "ACT"
    assert html =~ "INACT"
    assert has_element?(view, "#project-status-#{p1_id}", "Active")
    assert has_element?(view, "#project-status-#{p2_id}", "Inactive")
    assert has_element?(view, "#edit-project-#{p1_id}")
  end

  test "opens new project modal, validates, and creates project", %{admin_conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/projects")
    refute has_element?(view, "#project-modal")

    # Open modal
    view |> element("#new-project-button") |> render_click()
    assert has_element?(view, "#project-modal")
    assert has_element?(view, "#modal-title", "New Project")

    # Validate with empty inputs -> shows errors
    view
    |> form("#project-form", %{
      "project" => %{
        "name" => "",
        "github_repo" => "",
        "github_installation_id" => "",
        "linear_team_key" => "",
        "clone_path" => ""
      }
    })
    |> render_change()

    assert has_element?(view, "#project-name-error", "can't be blank")
    assert has_element?(view, "#project-github-repo-error", "can't be blank")

    expect(Rail.Git, :git_repo?, fn "/tmp/not-a-checkout" -> false end)

    view
    |> form("#project-form", %{"project" => %{"clone_path" => "/tmp/not-a-checkout"}})
    |> render_change()

    assert render(view) =~ "is not a git repository"

    # Submit with valid inputs
    id = System.unique_integer([:positive])
    repo = "example/created-#{id}"

    view
    |> form("#project-form", %{
      "project" => %{
        "name" => "Brand New Project",
        "github_repo" => repo,
        "github_installation_id" => "9988",
        "default_branch" => "main",
        "linear_team_key" => "BNP",
        "clone_path" => "/tmp/bnp",
        "active" => "true"
      }
    })
    |> render_submit()

    # Modal closes, project is in list
    refute has_element?(view, "#project-modal")
    assert render(view) =~ "Brand New Project"
    assert render(view) =~ repo
  end

  test "opens edit project modal, changes active status and name, and updates project", %{
    admin_conn: conn,
    admin_user: admin
  } do
    scope = Scope.for_user(admin)
    id = System.unique_integer([:positive])

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Editable App",
               github_repo: "example/edit-#{id}",
               github_installation_id: 333,
               linear_team_key: "EDT",
               default_branch: "main",
               clone_path: "/tmp/edit",
               active: true
             })

    assert {:ok, view, _html} = live(conn, ~p"/settings/projects")

    # Open edit modal
    view |> element("#edit-project-#{project_id}") |> render_click()
    assert has_element?(view, "#project-modal")
    assert has_element?(view, "#modal-title", "Edit Project")

    # Edit form
    view
    |> form("#project-form", %{
      "project" => %{
        "name" => "Renamed Editable App",
        "github_repo" => "example/edit-#{id}",
        "github_installation_id" => "333",
        "default_branch" => "develop",
        "linear_team_key" => "EDT",
        "clone_path" => "/tmp/edit",
        "active" => "false"
      }
    })
    |> render_submit()

    refute has_element?(view, "#project-modal")
    assert render(view) =~ "Renamed Editable App"
    assert has_element?(view, "#project-status-#{project_id}", "Inactive")
  end

  test "sets the script a project's new worktrees are set up with", %{admin_conn: conn, admin_user: admin} do
    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(Scope.for_user(admin), %{
               name: "Setup App",
               github_repo: "example/setup-#{System.unique_integer([:positive])}",
               github_installation_id: 334,
               linear_team_key: "SUP",
               default_branch: "main",
               clone_path: "/tmp/setup"
             })

    assert {:ok, view, _html} = live(conn, ~p"/settings/projects")
    view |> element("#edit-project-#{project_id}") |> render_click()

    assert view
           |> form("#project-form", %{"project" => %{"worktree_setup_script" => "/etc/setup"}})
           |> render_submit() =~ "must be a path inside the repository"

    view
    |> form("#project-form", %{"project" => %{"worktree_setup_script" => "scripts/setup-worktree.sh"}})
    |> render_submit()

    refute has_element?(view, "#project-modal")
    assert %Project{worktree_setup_script: "scripts/setup-worktree.sh"} = Repo.get!(Project, project_id)
  end

  test "sets the command a project's CI runs, and how long it may take", %{admin_conn: conn, admin_user: admin} do
    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(Scope.for_user(admin), %{
               name: "CI App",
               github_repo: "example/ci-#{System.unique_integer([:positive])}",
               github_installation_id: 335,
               linear_team_key: "CIA",
               default_branch: "main",
               clone_path: "/tmp/ci"
             })

    assert {:ok, view, _html} = live(conn, ~p"/settings/projects")
    view |> element("#edit-project-#{project_id}") |> render_click()

    assert view
           |> form("#project-form", %{"project" => %{"ci_command" => "mise run ci", "ci_timeout_minutes" => "0"}})
           |> render_submit() =~ "must be at least a minute"

    view
    |> form("#project-form", %{"project" => %{"ci_command" => "mise run ci", "ci_timeout_minutes" => "45"}})
    |> render_submit()

    assert %Project{ci_command: "mise run ci", ci_timeout_minutes: 45} = Repo.get!(Project, project_id)
  end

  test "links a project to a Linear workspace picked from the list", %{
    admin_conn: conn,
    admin_user: admin,
    project: %Project{linear_workspace_id: workspace_id}
  } do
    assert {:ok, %Project{id: project_id, linear_workspace_id: nil}} =
             Projects.create_project(Scope.for_user(admin), %{
               name: "Workspace App",
               github_repo: "example/workspace-#{System.unique_integer([:positive])}",
               github_installation_id: 334,
               linear_team_key: "WSP",
               default_branch: "main",
               clone_path: "/tmp/workspace"
             })

    assert {:ok, view, _html} = live(conn, ~p"/settings/projects")

    # Linking a workspace looks the team up through it, from the page's process.
    Req.Test.expect(Rail.Linear, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer lin_api_test_seed"]
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_wsp"}]}}})
    end)

    Req.Test.allow(Rail.Linear, self(), view.pid)

    view |> element("#edit-project-#{project_id}") |> render_click()
    assert has_element?(view, "#project-linear-workspace-input option[value='#{workspace_id}']", "Test Workspace")

    view |> form("#project-form", %{"project" => %{"linear_workspace_id" => workspace_id}}) |> render_submit()

    refute has_element?(view, "#project-modal")
    assert %Project{linear_workspace_id: ^workspace_id, linear_team_id: "lin_team_wsp"} = Repo.get!(Project, project_id)
  end

  test "a workspace that is gone is an error on the select", %{admin_conn: conn, project: %Project{id: project_id}} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/projects")
    view |> element("#edit-project-#{project_id}") |> render_click()

    render_submit(element(view, "#project-form"), %{"project" => %{"linear_workspace_id" => "lw_missing"}})

    assert has_element?(view, "#project-linear-workspace-error", "does not exist")
  end

  test "closes modal when cancel or close button is clicked", %{admin_conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/projects")

    view |> element("#new-project-button") |> render_click()
    assert has_element?(view, "#project-modal")

    view |> element("#close-modal-button") |> render_click()
    refute has_element?(view, "#project-modal")

    view |> element("#new-project-button") |> render_click()
    assert has_element?(view, "#project-modal")

    view |> element("#cancel-project-button") |> render_click()
    refute has_element?(view, "#project-modal")
  end

  test "validating with empty default_branch shows error", %{admin_conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/projects")
    view |> element("#new-project-button") |> render_click()

    view
    |> form("#project-form", %{
      "project" => %{
        "name" => "Foo",
        "default_branch" => ""
      }
    })
    |> render_change()

    assert has_element?(view, "#project-default-branch-error", "can't be blank")
  end

  test "submitting invalid form in new mode keeps modal open and shows errors", %{admin_conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/projects")
    view |> element("#new-project-button") |> render_click()

    view
    |> form("#project-form", %{
      "project" => %{
        "name" => "",
        "github_repo" => ""
      }
    })
    |> render_submit()

    assert has_element?(view, "#project-modal")
    assert has_element?(view, "#project-name-error", "can't be blank")
  end

  test "submitting invalid form in edit mode keeps modal open and shows errors", %{
    admin_conn: conn,
    admin_user: admin
  } do
    scope = Scope.for_user(admin)
    id = System.unique_integer([:positive])

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Edit Error Test",
               github_repo: "example/edit-err-#{id}",
               github_installation_id: 444,
               linear_team_key: "EE",
               default_branch: "main",
               clone_path: "/tmp/ee"
             })

    assert {:ok, view, _html} = live(conn, ~p"/settings/projects")
    view |> element("#edit-project-#{project_id}") |> render_click()

    view
    |> form("#project-form", %{
      "project" => %{
        "name" => ""
      }
    })
    |> render_submit()

    assert has_element?(view, "#project-modal")
    assert has_element?(view, "#project-name-error", "can't be blank")
  end

  test "edit_project with unknown id is ignored gracefully", %{admin_conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/projects")
    render_hook(view, "edit_project", %{"project_id" => "prj_000000000000000000000000"})
    refute has_element?(view, "#project-modal")
  end

  test "save event when modal is closed is ignored gracefully", %{admin_conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/settings/projects")
    render_hook(view, "save", %{"project" => %{}})
    refute has_element?(view, "#project-modal")
  end

  test "editing one project preserves other projects in the list", %{
    admin_conn: conn,
    admin_user: admin
  } do
    scope = Scope.for_user(admin)
    id = System.unique_integer([:positive])

    assert {:ok, %Project{id: p1_id}} =
             Projects.create_project(scope, %{
               name: "First Project",
               github_repo: "example/p1-#{id}",
               github_installation_id: 111,
               linear_team_key: "P1",
               default_branch: "main",
               clone_path: "/tmp/p1"
             })

    assert {:ok, %Project{id: p2_id}} =
             Projects.create_project(scope, %{
               name: "Second Project",
               github_repo: "example/p2-#{id}",
               github_installation_id: 222,
               linear_team_key: "P2",
               default_branch: "main",
               clone_path: "/tmp/p2"
             })

    assert {:ok, view, _html} = live(conn, ~p"/settings/projects")

    view |> element("#edit-project-#{p1_id}") |> render_click()

    view
    |> form("#project-form", %{
      "project" => %{
        "name" => "First Project Renamed",
        "github_repo" => "example/p1-#{id}",
        "github_installation_id" => "111",
        "default_branch" => "main",
        "linear_team_key" => "P1",
        "clone_path" => "/tmp/p1",
        "active" => "true"
      }
    })
    |> render_submit()

    assert has_element?(view, "#project-item-#{p1_id}")
    assert has_element?(view, "#project-item-#{p2_id}")
    assert render(view) =~ "First Project Renamed"
    assert render(view) =~ "Second Project"
  end
end
