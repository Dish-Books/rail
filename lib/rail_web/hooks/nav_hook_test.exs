defmodule RailWeb.Hooks.NavHookTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Projects
  alias Rail.Users

  test "handles switcher, theme, and rail toggle events", %{conn: conn} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Nav Hook Project 13119",
        github_repo: "org/nav-hook-13119",
        github_installation_id: 13_119,
        linear_team_key: "P13119",
        default_branch: "main",
        clone_path: "/tmp/repos/nav-hook-13119",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        },
        active: true
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_nav_hook_9",
        login: "nav_hook_user_9",
        email: "nav_hook_user_9@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    render_click(view, "toggle_rail", %{})
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
end
