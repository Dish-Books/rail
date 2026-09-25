defmodule RailWeb.Hooks.NavHookTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Users

  setup %{conn: conn, project: project} do
    {:ok, other_project} =
      Projects.create_project(system_scope(), %{
        name: "Nav Hook Other Project",
        github_repo: "org/nav-hook-other",
        github_installation_id: 13_120,
        linear_team_key: "OTH",
        default_branch: "main",
        clone_path: "/tmp/repos/nav-hook-other",
        linear_state_ids: %{"triage" => "st_triage"},
        active: true
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_nav_hook_selection",
        login: "nav_hook_selection_user",
        email: "nav_hook_selection_user@example.com",
        admin: false
      })

    issue =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_nav_hook_1",
        identifier: "TST-1",
        title: "Issue in the selected project",
        state: :triage
      })
      |> Repo.insert!()

    other_issue =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: other_project.id,
        external_id: "lin_nav_hook_2",
        identifier: "OTH-1",
        title: "Issue in the other project",
        state: :triage
      })
      |> Repo.insert!()
      |> Repo.preload(:project)

    {:ok, other_task} = Pipeline.create_task(other_issue, :product)

    %{
      conn: log_in_user(conn, user),
      other_project: other_project,
      issue: issue,
      other_issue: other_issue,
      other_task: other_task
    }
  end

  test "handles switcher, theme, and rail toggle events", %{conn: conn, project: project} do
    assert {:ok, view, _html} = live(conn, ~p"/issues")

    render_click(view, "toggle_rail", %{})
    render_click(view, "theme_changed", %{"theme" => "light"})
    render_click(view, "toggle_project_switcher", %{})
    assert has_element?(view, "#project-switcher-dialog")

    render_click(view, "close_project_switcher", %{})
    refute has_element?(view, "#project-switcher-dialog")

    render_click(view, "select_project", %{"project_id" => project.id})
    assert_redirect(view, ~p"/project-selection?#{[project_id: project.id, return_to: "/issues"]}")

    assert {:ok, view, _html} = live(conn, ~p"/issues")
    render_click(view, "select_project", %{"project_id" => ""})
    assert_redirect(view, ~p"/project-selection?#{[project_id: "", return_to: "/issues"]}")
  end

  test "opening an issue from another project keeps All projects", %{
    conn: conn,
    issue: issue,
    other_issue: other_issue
  } do
    assert {:ok, view, _html} = live(conn, ~p"/issues/#{other_issue.identifier}")
    assert has_element?(view, "#selected-project-name", "All projects")

    assert {:ok, issues, _html} = view |> element("#nav-issues") |> render_click() |> follow_redirect(conn)
    assert has_element?(issues, "#issue-card-#{issue.id}")
    assert has_element?(issues, "#issue-card-#{other_issue.id}")
  end

  test "opening a task from another project keeps the selected project", %{
    conn: conn,
    project: project,
    issue: issue,
    other_issue: other_issue,
    other_task: other_task
  } do
    conn = init_test_session(conn, %{selected_project_id: project.id})

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{other_task.id}")
    assert has_element?(view, "#selected-project-name", project.name)

    assert {:ok, overview, _html} = view |> element("#nav-overview") |> render_click() |> follow_redirect(conn)
    assert has_element?(overview, "#selected-project-name", project.name)

    assert {:ok, issues, _html} = overview |> element("#nav-issues") |> render_click() |> follow_redirect(conn)
    assert has_element?(issues, "#issues-subtitle", project.name)
    assert has_element?(issues, "#issue-card-#{issue.id}")
    refute has_element?(issues, "#issue-card-#{other_issue.id}")
  end

  test "the Issues breadcrumb returns to the list still filtered", %{
    conn: conn,
    project: project,
    issue: issue,
    other_issue: other_issue
  } do
    conn = init_test_session(conn, %{selected_project_id: project.id})

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{other_issue.identifier}")

    assert {:ok, issues, _html} = view |> element("#issue-back-link") |> render_click() |> follow_redirect(conn)
    assert has_element?(issues, "#issues-subtitle", project.name)
    assert has_element?(issues, "#issue-card-#{issue.id}")
    refute has_element?(issues, "#issue-card-#{other_issue.id}")
  end

  test "a page whose URL names no project keeps the selection", %{
    conn: conn,
    project: project,
    other_task: other_task
  } do
    conn = init_test_session(conn, %{selected_project_id: project.id})

    assert {:ok, issues, _html} = live(conn, ~p"/issues")
    assert has_element?(issues, "#selected-project-name", project.name)

    assert {:ok, task, _html} = live(conn, ~p"/tasks/#{other_task.id}")
    assert has_element?(task, "#selected-project-name", project.name)
  end

  test "a project in the URL does not change the selection", %{
    conn: conn,
    project: project,
    other_project: other_project,
    other_issue: other_issue
  } do
    conn = init_test_session(conn, %{selected_project_id: project.id})

    assert {:ok, view, _html} = live(conn, ~p"/issues?project=#{other_project.id}")
    assert has_element?(view, "#selected-project-name", project.name)
    refute has_element?(view, "#issue-card-#{other_issue.id}")
  end
end
