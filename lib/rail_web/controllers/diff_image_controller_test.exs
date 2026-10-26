defmodule RailWeb.DiffImageControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Pipeline
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users

  setup %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_diff_image_controller",
        login: "diff_image_controller_user",
        email: "diff_image_controller_user@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "logo.png"), "png bytes")
    task = learnings_task(project, "DIC-1", :review)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{conn: log_in_user(conn, user), task: task}
  end

  test "serves a side of a picture the diff changed, never sniffed or cached", %{conn: conn, task: task} do
    conn = get(conn, ~p"/tasks/#{task.id}/diff/new?#{[path: "logo.png", view: "uncommitted"]}")

    assert response(conn, 200) == "png bytes"
    assert ["image/png"] = get_resp_header(conn, "content-type")
    assert ["nosniff"] = get_resp_header(conn, "x-content-type-options")
    assert ["private, no-cache"] = get_resp_header(conn, "cache-control")
  end

  test "serves nothing that is not a side of a picture", %{conn: conn, task: task} do
    assert conn |> get(~p"/tasks/#{task.id}/diff/new?#{[path: "missing.png"]}") |> response(404)
    assert conn |> get(~p"/tasks/#{task.id}/diff/both?#{[path: "logo.png"]}") |> response(404)
    assert conn |> get(~p"/tasks/#{task.id}/diff/new") |> response(404)
    assert conn |> get(~p"/tasks/#{task.id}/diff/new?#{[path: "logo.png", view: "--output=x"]}") |> response(404)
    assert conn |> get(~p"/tasks/tsk_missing/diff/new?#{[path: "logo.png"]}") |> response(404)
  end

  test "serves nothing from a project the reader cannot open", %{conn: conn, task: task} do
    other =
      Repo.insert!(%Project{
        name: "Other",
        github_repo: "org/other-diff-images",
        github_installation_id: 2,
        default_branch: "main",
        key: "OTH",
        clone_path: "/tmp/repos/other-diff-images"
      })

    {:ok, _moved} = task |> Ecto.Changeset.change(project_id: other.id) |> Repo.update()

    assert conn |> get(~p"/tasks/#{task.id}/diff/new?#{[path: "logo.png"]}") |> response(404)
  end
end
