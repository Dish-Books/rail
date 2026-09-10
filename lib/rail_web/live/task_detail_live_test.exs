defmodule RailWeb.TaskDetailLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope

  test "redirects unauthenticated user to /auth/github", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/github"}}} = live(conn, ~p"/tasks/tsk_dummy")
  end

  test "renders task placeholder when task is not found", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/nonexistent-123")

    assert has_element?(view, "#task-detail-view")
    assert has_element?(view, "#task-detail-title", "Task Detail")
    assert has_element?(view, "#task-placeholder")
  end

  test "renders task details when task exists in database", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Detail Project",
               github_repo: "example/detail-project",
               github_installation_id: 603,
               linear_team_id: "t_det",
               linear_team_key: "DET",
               clone_path: "/tmp/detail-project",
               active: true
             })

    task =
      create_test_task(%{
        project_id: project_id,
        title: "Implement Login Flow",
        description: "Must handle OAuth callbacks cleanly",
        stage: :engineer,
        stage_state: :running
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#task-detail-view")
    assert has_element?(view, "#task-detail-title", "Implement Login Flow")
    assert has_element?(view, "#task-details-pane")
    assert has_element?(view, "#task-details-pane", "Stage: engineer (running)")
    assert has_element?(view, "#task-details-pane", "Must handle OAuth callbacks cleanly")
  end

  test "handles ?project=<id> param and project switcher", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id, name: project_name}} =
             Projects.create_project(scope, %{
               name: "Project Switcher Task",
               github_repo: "example/pst",
               github_installation_id: 604,
               linear_team_id: "t_pst",
               linear_team_key: "PST",
               clone_path: "/tmp/pst",
               active: true
             })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/some-task?project=#{project_id}")
    assert has_element?(view, "#selected-project-name", project_name)

    # Patch without project
    view |> element("#project-switcher-button") |> render_click()
    view |> element("#project-option-all") |> render_click()

    assert_patched(view, ~p"/tasks/some-task")
    assert has_element?(view, "#selected-project-name", "All projects")
  end
end
