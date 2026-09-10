defmodule RailWeb.Hooks.NavHookTest do
  use RailWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias RailTest.Mocks.Linear, as: LinearMock

  test "open_new_issue sets default project to current_project_id when active", %{conn: conn} do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    _project1 =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          name: "Project One",
          linear_team_key: "ONE",
          active: true
      })

    project2 =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          name: "Project Two",
          linear_team_key: "TWO",
          active: true
      })

    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues?project=#{project2.id}")

    refute has_element?(view, "#capture-idea-dialog")

    view
    |> element("#global-capture-idea-button")
    |> render_click()

    assert has_element?(view, "#capture-idea-dialog")
    assert has_element?(view, "#capture-modal-title", "New Issue")
    assert has_element?(view, "#capture-project-dropdown option[value='#{project2.id}'][selected]")
  end

  test "open_new_issue falls back to first active project when current_project_id is not set or inactive", %{
    conn: conn
  } do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    _inactive =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          name: "Inactive Project",
          active: false
      })

    active =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          name: "Active First",
          linear_team_key: "ACT",
          active: true
      })

    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    view
    |> element("#new-issue-button")
    |> render_click()

    assert has_element?(view, "#capture-idea-dialog")
    assert has_element?(view, "#capture-project-dropdown option[value='#{active.id}'][selected]")
  end

  test "close_new_issue dismisses the modal", %{conn: conn} do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    _project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id, active: true})

    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    render_click(view, "open_new_issue", %{})
    assert has_element?(view, "#capture-idea-dialog")

    render_click(view, "close_new_issue", %{})
    refute has_element?(view, "#capture-idea-dialog")
  end

  test "capture_form_change updates form values and enables submit button", %{conn: conn} do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    _project1 =
      Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id, name: "Prj 1", active: true})

    project2 =
      Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id, name: "Prj 2", active: true})

    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    render_click(view, "open_new_issue", %{})
    assert has_element?(view, "#capture-submit-button[disabled]")

    view
    |> form("#capture-issue-form", %{
      "ask" => "Support offline mode",
      "project_id" => project2.id,
      "priority" => "urgent"
    })
    |> render_change()

    assert has_element?(view, "#capture-idea-input", "Support offline mode")
    assert has_element?(view, "#capture-project-dropdown option[value='#{project2.id}'][selected]")
    assert has_element?(view, "#capture-priority-dropdown option[value='urgent'][selected]")
    refute has_element?(view, "#capture-submit-button[disabled]")
  end

  test "capture_form_submit does nothing when ask is blank", %{conn: conn} do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id, active: true})

    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    render_click(view, "open_new_issue", %{})

    render_submit(view, "capture_form_submit", %{
      "ask" => "   ",
      "project_id" => project.id,
      "priority" => "medium"
    })

    assert has_element?(view, "#capture-idea-dialog")
    refute has_element?(view, "#capture-error-banner")
  end

  test "capture_form_submit fails gracefully when project is not found", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    render_click(view, "open_new_issue", %{})

    render_submit(view, "capture_form_submit", %{
      "ask" => "Some idea",
      "project_id" => "nonexistent_project_id",
      "priority" => "medium"
    })

    assert has_element?(view, "#capture-idea-dialog")
    assert has_element?(view, "#capture-error-banner", "Project not found")
  end

  test "capture_form_submit creates issue, resets form, and broadcasts pipeline_changed", %{
    conn: conn
  } do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    project =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          linear_team_id: "team_nav_ok",
          linear_state_ids: %{"triage" => "st_triage_ok"},
          active: true
      })

    {authed_conn, _user} = log_in_test_user(conn)

    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline_changed")
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_nav_captured",
      "identifier" => "NAV-101",
      "title" => "Capture via LiveView",
      "description" => "Capture via LiveView\nMultiline body",
      "state" => %{"id" => "st_triage_ok", "name" => "Triage", "type" => "triage"},
      "branchName" => "nav-101-branch",
      "url" => "https://linear.app/issue/NAV-101",
      "createdAt" => "2026-09-02T10:00:00.000Z",
      "updatedAt" => "2026-09-02T10:00:00.000Z"
    })

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    render_click(view, "open_new_issue", %{})

    view
    |> form("#capture-issue-form", %{
      "ask" => "Capture via LiveView\nMultiline body",
      "project_id" => project.id,
      "priority" => "high"
    })
    |> render_submit()

    # Modal is closed on success
    refute has_element?(view, "#capture-idea-dialog")

    # PubSub broadcast received
    assert_receive :pipeline_changed
    assert_receive {:pipeline_changed, %{event: :issue_captured, issue_id: "iss_" <> _}}
  end

  test "capture_form_submit keeps modal open and preserves ask text on error", %{conn: conn} do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    project =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          linear_team_id: "team_nav_err",
          linear_state_ids: %{"triage" => "st_triage_err"},
          active: true
      })

    {authed_conn, _user} = log_in_test_user(conn)

    LinearMock.mock_mutation_failure("issueCreate")

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    render_click(view, "open_new_issue", %{})

    view
    |> form("#capture-issue-form", %{
      "ask" => "Critical production defect",
      "project_id" => project.id,
      "priority" => "urgent"
    })
    |> render_submit()

    # Modal remains open
    assert has_element?(view, "#capture-idea-dialog")
    # Ask text is preserved
    assert has_element?(view, "#capture-idea-input", "Critical production defect")
    # Error banner is visible
    assert has_element?(view, "#capture-error-banner")
  end

  test "handles switcher, theme, and rail toggle events", %{conn: conn} do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id, active: true})

    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    render_click(view, "toggle_rail", %{})
    render_click(view, "toggle_theme", %{})
    render_click(view, "theme_changed", %{"theme" => "light"})
    render_click(view, "toggle_project_switcher", %{})
    assert has_element?(view, "#project-switcher-dialog")

    render_click(view, "close_project_switcher", %{})
    refute has_element?(view, "#project-switcher-dialog")

    render_click(view, "select_project", %{"project_id" => project.id})
    assert_patched(view, ~p"/issues?project=#{project.id}")

    render_click(view, "select_project", %{"project_id" => ""})
    assert_patched(view, ~p"/issues")
  end

  test "handles live_sync and pipeline_changed info messages", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    send(view.pid, {:live_sync, %{}})
    send(view.pid, :pipeline_changed)
    send(view.pid, %{event: "pipeline_changed"})
    send(view.pid, :unhandled_message)

    assert has_element?(view, "#issues-view")
  end

  test "open_new_issue sets default_project_id to nil when no active projects exist", %{
    conn: conn
  } do
    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    render_click(view, "open_new_issue", %{})
    assert has_element?(view, "#capture-idea-dialog")
  end

  test "capture_form_submit with empty project_id fails with project not found", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    render_click(view, "open_new_issue", %{})

    render_submit(view, "capture_form_submit", %{
      "ask" => "Idea without project",
      "project_id" => "",
      "priority" => "medium"
    })

    assert has_element?(view, "#capture-error-banner", "Project not found")
  end

  test "capture_form_submit falls back to medium on invalid priority and fetches project from database", %{
    conn: conn
  } do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    # Project created after mount so it must be fetched from DB via fetch_project
    late_project =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          linear_team_id: "team_late",
          linear_state_ids: %{"triage" => "st_triage_late"},
          active: true
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_nav_late",
      "identifier" => "NAV-102",
      "title" => "Late project issue",
      "description" => "Late project description",
      "state" => %{"id" => "st_triage_late", "name" => "Triage", "type" => "triage"},
      "branchName" => "nav-102",
      "url" => "https://linear.app/issue/NAV-102",
      "createdAt" => "2026-09-02T10:00:00.000Z",
      "updatedAt" => "2026-09-02T10:00:00.000Z"
    })

    render_click(view, "open_new_issue", %{})

    render_submit(view, "capture_form_submit", %{
      "ask" => "Late project description",
      "project_id" => late_project.id,
      "priority" => "invalid_priority_string"
    })

    refute has_element?(view, "#capture-idea-dialog")
  end

  test "capture_form_submit handles string error and atom error correctly", %{conn: conn} do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id, active: true})

    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    render_click(view, "open_new_issue", %{})

    # String error from capture_issue
    expect(Rail.Issues, :capture_issue, fn _scope, _project, _ask, _opts ->
      {:error, "Direct string failure"}
    end)

    render_submit(view, "capture_form_submit", %{
      "ask" => "Testing string error",
      "project_id" => project.id,
      "priority" => "medium"
    })

    assert has_element?(view, "#capture-error-banner", "Direct string failure")

    # Atom error from capture_issue
    expect(Rail.Issues, :capture_issue, fn _scope, _project, _ask, _opts ->
      {:error, :not_authorized}
    end)

    render_submit(view, "capture_form_submit", %{
      "ask" => "Testing atom error",
      "project_id" => project.id,
      "priority" => "medium"
    })

    assert has_element?(view, "#capture-error-banner", "not_authorized")
  end
end
