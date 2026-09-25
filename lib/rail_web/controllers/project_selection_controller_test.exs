defmodule RailWeb.ProjectSelectionControllerTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Users

  setup %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_project_selection",
        login: "project_selection_user",
        email: "project_selection_user@example.com",
        admin: false
      })

    %{conn: log_in_user(conn, user)}
  end

  test "an unauthenticated request redirects to sign-in", %{project: project} do
    conn = get(build_conn(), ~p"/project-selection?#{[project_id: project.id, return_to: "/issues"]}")

    assert redirected_to(conn) == ~p"/sign-in"
  end

  test "a pick is stored and the page it returns to shows it", %{conn: conn, project: project} do
    conn = get(conn, ~p"/project-selection?#{[project_id: project.id, return_to: "/issues"]}")

    assert redirected_to(conn) == ~p"/issues"
    assert get_session(conn, :selected_project_id) == project.id

    assert {:ok, view, _html} = live(conn, ~p"/issues")
    assert has_element?(view, "#selected-project-name", project.name)
  end

  test "picking All projects clears the selection", %{conn: conn, project: project} do
    conn =
      conn
      |> init_test_session(%{selected_project_id: project.id})
      |> get(~p"/project-selection?#{[project_id: "", return_to: "/issues"]}")

    assert redirected_to(conn) == ~p"/issues"
    assert get_session(conn, :selected_project_id) == nil
  end

  test "a return_to that is not a local path redirects home", %{conn: conn, project: project} do
    for return_to <- ["//evil.example", "https://evil.example", "evil.example/issues", "/\\evil.example"] do
      conn = get(conn, ~p"/project-selection?#{[project_id: project.id, return_to: return_to]}")
      assert redirected_to(conn) == ~p"/"
    end

    conn = get(conn, ~p"/project-selection?#{[project_id: project.id]}")
    assert redirected_to(conn) == ~p"/"
  end
end
