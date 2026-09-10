defmodule RailWeb.OverviewLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope

  test "redirects unauthenticated user to /auth/github", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/github"}}} = live(conn, ~p"/")
  end

  test "renders Overview view and navigation rail with active Overview destination", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/")

    assert has_element?(view, "#overview-view")
    assert has_element?(view, "#overview-title", "Overview")
    assert has_element?(view, "#running-agent-count-pill", "0 agents running")

    # Nav rail checks
    assert has_element?(view, "#navigation-rail")
    assert has_element?(view, "#nav-overview[data-active='true']")
    assert has_element?(view, "#nav-issues[data-active='false']")
    assert has_element?(view, "#nav-cli-accounts[data-active='false']")
    assert has_element?(view, "#nav-settings[data-active='false']")

    # Top app bar checks
    assert has_element?(view, "#top-app-bar")
    assert has_element?(view, "#section-title", "Overview")
    assert has_element?(view, "#project-switcher-button")
    assert has_element?(view, "#global-capture-idea-button")
    assert has_element?(view, "#theme-toggle-button")
  end

  test "project switcher displays active projects count and switches projects via handle_params", %{
    conn: conn
  } do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: p1_id, name: p1_name}} =
             Projects.create_project(scope, %{
               name: "Project One",
               github_repo: "example/p1",
               github_installation_id: 111,
               linear_team_id: "t1",
               linear_team_key: "P1",
               clone_path: "/tmp/p1",
               active: true
             })

    assert {:ok, %Project{id: p2_id, name: p2_name}} =
             Projects.create_project(scope, %{
               name: "Project Two",
               github_repo: "example/p2",
               github_installation_id: 222,
               linear_team_id: "t2",
               linear_team_key: "P2",
               clone_path: "/tmp/p2",
               active: true
             })

    assert {:ok, view, _html} = live(authed_conn, ~p"/")

    # Initial state: All projects
    assert has_element?(view, "#selected-project-name", "All projects")
    assert has_element?(view, "#active-project-count", "2")
    refute has_element?(view, "#project-switcher-dialog")

    # Open project switcher
    view |> element("#project-switcher-button") |> render_click()
    assert has_element?(view, "#project-switcher-dialog")
    assert has_element?(view, "#project-option-#{p1_id}", p1_name)
    assert has_element?(view, "#project-option-#{p2_id}", p2_name)

    # Select Project One
    view |> element("#project-option-#{p1_id}") |> render_click()

    # URL updated to ?project=p1_id via push_patch and handle_params
    assert_patched(view, ~p"/?project=#{p1_id}")
    refute has_element?(view, "#project-switcher-dialog")
    assert has_element?(view, "#selected-project-name", p1_name)

    # Switch back to All projects
    view |> element("#project-switcher-button") |> render_click()
    view |> element("#project-option-all") |> render_click()

    assert_patched(view, ~p"/")
    assert has_element?(view, "#selected-project-name", "All projects")
  end

  test "mount with ?project=<id> in query params sets current_project_id", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id, name: project_name}} =
             Projects.create_project(scope, %{
               name: "Preset Project",
               github_repo: "example/preset",
               github_installation_id: 333,
               linear_team_id: "tp",
               linear_team_key: "PRE",
               clone_path: "/tmp/preset",
               active: true
             })

    assert {:ok, view, _html} = live(authed_conn, ~p"/?project=#{project_id}")
    assert has_element?(view, "#selected-project-name", project_name)
  end

  test "toggles navigation rail expanded and collapsed state", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/")
    assert has_element?(view, "#brand-name", "Rail")

    # Collapse rail
    view |> element("#rail-toggle") |> render_click()
    refute has_element?(view, "#brand-name")

    # Expand rail
    view |> element("#rail-toggle") |> render_click()
    assert has_element?(view, "#brand-name", "Rail")
  end

  test "toggles theme mode between dark and light", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/")
    assert has_element?(view, "#theme-toggle-button[title='Switch to Light mode']")

    # Toggle to light
    view |> element("#theme-toggle-button") |> render_click()
    assert has_element?(view, "#theme-toggle-button[title='Switch to Dark mode']")

    # Toggle back to dark
    view |> element("#theme-toggle-button") |> render_click()
    assert has_element?(view, "#theme-toggle-button[title='Switch to Light mode']")

    # Client hook event
    render_hook(view, "theme_changed", %{"theme" => "light"})
    assert has_element?(view, "#theme-toggle-button[title='Switch to Dark mode']")
  end

  test "opens and closes new issue modal", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/")
    refute has_element?(view, "#new-issue-modal")

    # Open modal
    view |> element("#global-capture-idea-button") |> render_click()
    assert has_element?(view, "#new-issue-modal")
    assert has_element?(view, "#modal-headline", "New Issue")

    # Close modal
    view |> element("#close-new-issue-button") |> render_click()
    refute has_element?(view, "#new-issue-modal")
  end

  test "close_project_switcher event closes open dialog", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/")
    view |> element("#project-switcher-button") |> render_click()
    assert has_element?(view, "#project-switcher-dialog")

    render_hook(view, "close_project_switcher", %{})
    refute has_element?(view, "#project-switcher-dialog")
  end

  test "renders attention badge when tasks require attention and reacts to pipeline_changed", %{
    conn: conn
  } do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Attention App",
               github_repo: "example/att",
               github_installation_id: 444,
               linear_team_id: "t_att",
               linear_team_key: "ATT",
               clone_path: "/tmp/att",
               active: true
             })

    _task =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :failed
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/")
    assert has_element?(view, "#attention-badge")

    # Send PubSub message pipeline_changed
    send(view.pid, :pipeline_changed)
    assert has_element?(view, "#attention-badge")

    send(view.pid, %{event: "pipeline_changed"})
    assert has_element?(view, "#attention-badge")

    send(view.pid, {:live_sync, %{table: "tasks"}})
    assert has_element?(view, "#attention-badge")
  end

  test "renders singular running agent label when running_count is 1", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Running Project",
               github_repo: "example/running",
               github_installation_id: 555,
               linear_team_id: "t_run",
               linear_team_key: "RUN",
               clone_path: "/tmp/running",
               active: true
             })

    _task =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :running
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/")
    assert has_element?(view, "#running-agent-count-pill", "1 agent running")

    # Verify handle_info updates running count when new task runs
    _task2 =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :running
      })

    send(view.pid, :pipeline_changed)
    assert has_element?(view, "#running-agent-count-pill", "2 agents running")

    # Send unknown info message to test fallback handle_info
    send(view.pid, :unhandled_info_message)
    assert has_element?(view, "#running-agent-count-pill", "2 agents running")
  end

  test "running count with project filter updates via live_sync and pipeline_changed", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: p1_id}} =
             Projects.create_project(scope, %{
               name: "Project P1",
               github_repo: "example/p1-run",
               github_installation_id: 881,
               linear_team_id: "t_p1",
               linear_team_key: "P1R",
               clone_path: "/tmp/p1-run",
               active: true
             })

    assert {:ok, %Project{id: p2_id}} =
             Projects.create_project(scope, %{
               name: "Project P2",
               github_repo: "example/p2-run",
               github_installation_id: 882,
               linear_team_id: "t_p2",
               linear_team_key: "P2R",
               clone_path: "/tmp/p2-run",
               active: true
             })

    _task1 =
      create_test_task(%{
        project_id: p1_id,
        stage: :engineer,
        stage_state: :running
      })

    _task2 =
      create_test_task(%{
        project_id: p2_id,
        stage: :engineer,
        stage_state: :running
      })

    # When viewing P1 only, running count should be 1
    assert {:ok, view, _html} = live(authed_conn, ~p"/?project=#{p1_id}")
    assert has_element?(view, "#running-agent-count-pill", "1 agent running")

    # Send live_sync message
    send(view.pid, {:live_sync, %{table: "tasks"}})
    assert has_element?(view, "#running-agent-count-pill", "1 agent running")

    # Send event map message
    send(view.pid, %{event: "pipeline_changed"})
    assert has_element?(view, "#running-agent-count-pill", "1 agent running")
  end
end
