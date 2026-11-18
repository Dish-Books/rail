defmodule RailWeb.AttachmentControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users

  setup %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_attachment_controller",
        login: "attachment_controller_user",
        email: "attachment_controller_user@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    task = learnings_task(project, "ATC-1")
    folder = Path.join(task.scratch_path, "attachments")
    File.mkdir_p!(folder)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    name = "#{Ecto.UUID.generate()}.png"
    File.write!(Path.join(folder, name), "png bytes")

    %{conn: log_in_user(conn, user), task: task, name: name}
  end

  test "serves a sent picture typed by its extension, never sniffed and never run", %{
    conn: conn,
    task: task,
    name: name
  } do
    conn = get(conn, ~p"/tasks/#{task.id}/attachments/#{name}")

    assert response(conn, 200) == "png bytes"
    assert ["image/png"] = get_resp_header(conn, "content-type")
    assert ["nosniff"] = get_resp_header(conn, "x-content-type-options")
    assert ["sandbox"] = get_resp_header(conn, "content-security-policy")
  end

  # Only a name in the shape a send writes is read, so the worst an invented one gets is a 404.
  test "serves nothing a send did not write", %{conn: conn, task: task, name: name} do
    assert conn |> get(~p"/tasks/#{task.id}/attachments/#{"#{Ecto.UUID.generate()}.png"}") |> response(404)
    assert conn |> get(~p"/tasks/#{task.id}/attachments/..%2F..%2Fetc") |> response(404)
    assert conn |> get(~p"/tasks/#{task.id}/attachments/notes.txt") |> response(404)
    assert conn |> get(~p"/tasks/tsk_missing/attachments/#{name}") |> response(404)
  end

  test "serves nothing from a project the reader cannot open", %{conn: conn, task: task, name: name} do
    other =
      Repo.insert!(%Project{
        name: "Other",
        github_repo: "org/other-attachments",
        github_installation_id: 2,
        default_branch: "main",
        key: "OTHAT",
        clone_path: "/tmp/repos/other-attachments"
      })

    {:ok, _moved} = task |> Ecto.Changeset.change(project_id: other.id) |> Repo.update()

    assert conn |> get(~p"/tasks/#{task.id}/attachments/#{name}") |> response(404)
  end
end
