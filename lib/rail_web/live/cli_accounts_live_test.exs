defmodule RailWeb.CliAccountsLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope

  test "redirects unauthenticated user to /auth/github", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/github"}}} = live(conn, ~p"/cli-accounts")
  end

  test "renders CLI Accounts view and navigation rail with active CLI Accounts destination", %{
    conn: conn
  } do
    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/cli-accounts")

    assert has_element?(view, "#cli-accounts-view")
    assert has_element?(view, "#cli-accounts-title", "CLI Accounts")

    # Nav rail checks
    assert has_element?(view, "#navigation-rail")
    assert has_element?(view, "#nav-overview[data-active='false']")
    assert has_element?(view, "#nav-issues[data-active='false']")
    assert has_element?(view, "#nav-cli-accounts[data-active='true']")
    assert has_element?(view, "#nav-settings[data-active='false']")

    # Top app bar checks
    assert has_element?(view, "#top-app-bar")
    assert has_element?(view, "#section-title", "CLI Accounts")
  end

  test "handles ?project=<id> param and updates project switcher", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id, name: project_name}} =
             Projects.create_project(scope, %{
               name: "CLI Project",
               github_repo: "example/cli-project",
               github_installation_id: 602,
               linear_team_id: "t_cli",
               linear_team_key: "CLI",
               clone_path: "/tmp/cli-project",
               active: true
             })

    assert {:ok, view, _html} = live(authed_conn, ~p"/cli-accounts?project=#{project_id}")
    assert has_element?(view, "#selected-project-name", project_name)

    # Patch without project
    view |> element("#project-switcher-button") |> render_click()
    view |> element("#project-option-all") |> render_click()

    assert_patched(view, ~p"/cli-accounts")
    assert has_element?(view, "#selected-project-name", "All projects")
  end
end
