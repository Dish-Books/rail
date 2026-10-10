defmodule RailWeb.ScreenControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Pipeline
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users

  setup %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_screen_controller",
        login: "screen_controller_user",
        email: "screen_controller_user@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    task = learnings_task(project, "SCT-1", :review)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
    folder = Path.join([task.scratch_path, "qa", "screens", "toolbar"])
    File.mkdir_p!(folder)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    File.write!(Path.join(folder, "1.jpg"), "jpeg bytes")
    {:ok, _shot} = Pipeline.save_screen(task, %{key: "toolbar", label: "Toolbar", file: "screens/toolbar/1.jpg"})

    %{conn: log_in_user(conn, user), task: task, user: user}
  end

  test "serves a listed shot as a picture, never sniffed or cached", %{conn: conn, task: task} do
    conn = get(conn, ~p"/tasks/#{task.id}/screens/toolbar/0")

    assert response(conn, 200) == "jpeg bytes"
    assert ["image/jpeg"] = get_resp_header(conn, "content-type")
    assert ["nosniff"] = get_resp_header(conn, "x-content-type-options")
    assert ["private, no-cache"] = get_resp_header(conn, "cache-control")
  end

  # The file is the listing's, never the URL's, so the worst an invented name gets is a 404.
  test "serves nothing the listing does not name", %{conn: conn, task: task} do
    File.write!(Path.join([task.scratch_path, "qa", "screens", "toolbar", "2.jpg"]), "unlisted")

    assert conn |> get(~p"/tasks/#{task.id}/screens/toolbar/1") |> response(404)
    assert conn |> get(~p"/tasks/#{task.id}/screens/toolbar/first") |> response(404)
    assert conn |> get(~p"/tasks/#{task.id}/screens/other/0") |> response(404)
    assert conn |> get(~p"/tasks/#{task.id}/screens/..%2F..%2Fetc/0") |> response(404)
    assert conn |> get(~p"/tasks/tsk_missing/screens/toolbar/0") |> response(404)
  end

  test "serves nothing from a project the reader cannot open", %{conn: conn, task: task} do
    other =
      Repo.insert!(%Project{
        name: "Other",
        github_repo: "org/other-screens",
        github_installation_id: 2,
        default_branch: "main",
        linear_team_key: "OTH",
        clone_path: "/tmp/repos/other-screens"
      })

    {:ok, _moved} = task |> Ecto.Changeset.change(project_id: other.id) |> Repo.update()

    assert conn |> get(~p"/tasks/#{task.id}/screens/toolbar/0") |> response(404)
  end
end
