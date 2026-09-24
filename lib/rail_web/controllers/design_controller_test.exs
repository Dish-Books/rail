defmodule RailWeb.DesignControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Users

  setup %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_design_controller",
        login: "design_controller_user",
        email: "design_controller_user@example.com"
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_design_controller_1", "identifier" => "DCT-1", "title" => "Design Controller"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Design Controller"})
    {:ok, task} = Pipeline.create_task(issue, :design)
    design_dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(design_dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    File.write!(Path.join(design_dir, "manifest.json"), ~s({"options": [{"key": "cards", "title": "Cards"}]}))
    File.write!(Path.join(design_dir, "cards.html"), "<h1>Cards</h1>")
    File.write!(Path.join(design_dir, "cards.png"), "png bytes")
    File.write!(Path.join(design_dir, "stray.html"), "<h1>Not an option</h1>")

    %{conn: log_in_user(conn, user), task: task, design_dir: design_dir}
  end

  test "serves an option's page sandboxed away from Rail's origin", %{conn: conn, task: task} do
    conn = get(conn, ~p"/tasks/#{task.id}/design/cards")

    assert html_response(conn, 200) == "<h1>Cards</h1>"
    assert get_resp_header(conn, "content-security-policy") == ["sandbox allow-scripts"]
  end

  test "serves an option's screenshot", %{conn: conn, task: task} do
    conn = get(conn, ~p"/tasks/#{task.id}/design/cards/screenshot")

    assert response(conn, 200) == "png bytes"
    assert response_content_type(conn, :png) =~ "image/png"
  end

  test "serves nothing the manifest does not name", %{conn: conn, task: task, design_dir: dir} do
    assert conn |> get(~p"/tasks/#{task.id}/design/stray") |> response(404)
    assert conn |> get(~p"/tasks/tsk_missing/design/cards") |> response(404)

    File.rm!(Path.join(dir, "cards.png"))
    assert conn |> get(~p"/tasks/#{task.id}/design/cards/screenshot") |> response(404)
  end
end
