defmodule RailWeb.DemoControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Users

  setup %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_demo_controller",
        login: "demo_controller_user",
        email: "demo_controller_user@example.com"
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_demo_controller_1", "identifier" => "DCT-1", "title" => "Demo Controller"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Demo Controller"})
    {:ok, task} = Pipeline.create_task(issue, :demo)
    demo_dir = Path.join(task.scratch_path, "demo")
    File.mkdir_p!(demo_dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    File.write!(Path.join(demo_dir, "demo.webm"), "0123456789")

    %{conn: log_in_user(conn, user), task: task, demo_dir: demo_dir}
  end

  test "serves the recording a demo run made", %{conn: conn, task: task} do
    conn = get(conn, ~p"/tasks/#{task.id}/demo/video")

    assert response(conn, 200) == "0123456789"
    assert response_content_type(conn, :webm) =~ "video/webm"
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
  end

  # A player handed the whole file plays it from the start and nothing else, so
  # seeking to a beat needs the range it asked for.
  test "answers the range a player asks for", %{conn: conn, task: task} do
    conn = conn |> put_req_header("range", "bytes=2-5") |> get(~p"/tasks/#{task.id}/demo/video")

    assert response(conn, 206) == "2345"
    assert get_resp_header(conn, "content-range") == ["bytes 2-5/10"]
  end

  test "a range with no end runs to the end of the file", %{conn: conn, task: task} do
    conn = conn |> put_req_header("range", "bytes=7-") |> get(~p"/tasks/#{task.id}/demo/video")

    assert response(conn, 206) == "789"
    assert get_resp_header(conn, "content-range") == ["bytes 7-9/10"]
  end

  test "a range past the end of the file is answered with the whole of it", %{conn: conn, task: task} do
    conn = conn |> put_req_header("range", "bytes=40-50") |> get(~p"/tasks/#{task.id}/demo/video")

    assert response(conn, 200) == "0123456789"
  end

  # Anything else is answered with the whole file, which is always a correct
  # answer to a range request even when it is not the best one.
  test "a range Rail does not understand is answered with the whole file", %{conn: conn, task: task} do
    for range <- ["bytes=nonsense", "bytes=5-2", "bytes=1-2-3", "seconds=0-4"] do
      conn = conn |> put_req_header("range", range) |> get(~p"/tasks/#{task.id}/demo/video")

      assert response(conn, 200) == "0123456789"
    end
  end

  test "a task with no recording has nothing to serve", %{conn: conn, task: task, demo_dir: demo_dir} do
    File.rm!(Path.join(demo_dir, "demo.webm"))

    assert conn |> get(~p"/tasks/#{task.id}/demo/video") |> response(404)
  end

  test "a task that is not a task has nothing to serve", %{conn: conn} do
    assert conn |> get(~p"/tasks/tsk_missing/demo/video") |> response(404)
  end
end
