defmodule RailWeb.IssueAssetControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Clients.R2
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Users

  setup %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issue_asset",
        login: "issue_asset_user",
        email: "issue_asset_user@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_issue_asset", "identifier" => "IAS-1", "title" => "Issue Asset Issue"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Issue Asset Issue"})

    %{conn: log_in_user(conn, user), issue: issue}
  end

  test "serves a Linear image the page cannot fetch for itself", %{conn: conn, issue: issue} do
    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/ws_id/issue_id/screenshot.png"
      assert conn.query_string == "signature=abc"

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, "PNG_BYTES")
    end)

    conn = get(conn, ~p"/issues/#{issue.id}/assets/ws_id/issue_id/screenshot.png?signature=abc")

    assert response(conn, 200) == "PNG_BYTES"
    assert response_content_type(conn, :png) =~ "image/png"
  end

  test "a file Linear will not serve is not found", %{conn: conn, issue: issue} do
    Req.Test.expect(Rail.Linear, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

    conn = get(conn, ~p"/issues/#{issue.id}/assets/ws_id/gone.png")

    assert response(conn, 404) == "Not found"
  end

  test "an issue that is not there has no files", %{conn: conn} do
    conn = get(conn, ~p"/issues/iss_missing/assets/ws_id/screenshot.png")

    assert response(conn, 404) == "Not found"
  end

  test "an issue in a project the user cannot access has no files, while an admin is served", %{
    conn: conn,
    issue: issue
  } do
    {:ok, outsider} =
      Users.register_oauth_user(%{
        github_id: "gh_outsider",
        login: "outsider-issue-asset-controller",
        email: "outsider-issue-asset-controller@example.com"
      })

    {:ok, outsider} = Users.update_user(system_scope(), outsider, %{project_ids: ["prj_other"]})
    conn = log_in_user(conn, outsider)

    assert conn |> get(~p"/issues/#{issue.id}/assets/ws_id/screenshot.png") |> response(404) == "Not found"

    {:ok, admin} =
      Users.register_oauth_user(%{
        github_id: "gh_asset_admin",
        login: "asset_admin",
        email: "a-issue-asset-controller@x.com",
        admin: true
      })

    Req.Test.expect(Rail.Linear, fn conn -> Plug.Conn.send_resp(conn, 200, "PNG_BYTES") end)

    assert conn |> log_in_user(admin) |> get(~p"/issues/#{issue.id}/assets/ws_id/screenshot.png") |> response(200) ==
             "PNG_BYTES"
  end

  test "serves a Rail-tracked issue's file from R2, and none through another issue's address", %{conn: conn} do
    n = System.unique_integer([:positive])

    {:ok, local} =
      Projects.create_project(system_scope(), %{
        name: "Kept in Rail",
        github_repo: "example/asset-#{n}",
        github_installation_id: 1,
        tracker: :local,
        key: "AST#{n}",
        default_branch: "main",
        clone_path: "/tmp/asset-#{n}"
      })

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_local_asset", login: "local_asset", email: "local_asset@example.com"})

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [local.id]})
    {:ok, %Issue{id: issue_id}} = Issues.create_issue(system_scope(), local, %{title: "Has a screenshot"})
    {:ok, %Issue{id: other_id}} = Issues.create_issue(system_scope(), local, %{title: "Has none"})
    name = "#{Ecto.UUID.generate()}-AST-1-chips.png"
    conn = log_in_user(conn, user)

    path = "/r2_bucket/#{issue_id}/#{name}"

    Req.Test.expect(R2, fn r2 ->
      assert %Plug.Conn{method: "GET", request_path: ^path} = r2

      r2
      |> Plug.Conn.put_resp_content_type("image/png", nil)
      |> Plug.Conn.send_resp(200, "PNG_BYTES")
    end)

    served = get(conn, "/issues/#{issue_id}/assets/#{name}")
    assert response(served, 200) == "PNG_BYTES"
    assert response_content_type(served, :png) =~ "image/png"

    other_path = "/r2_bucket/#{other_id}/#{name}"

    Req.Test.expect(R2, fn r2 ->
      assert %Plug.Conn{request_path: ^other_path} = r2
      Plug.Conn.send_resp(r2, 404, "NoSuchKey")
    end)

    assert conn |> get("/issues/#{other_id}/assets/#{name}") |> response(404) == "Not found"
    assert conn |> get("/issues/#{other_id}/assets/#{issue_id}/#{name}") |> response(404) == "Not found"
    assert conn |> get("/issues/#{other_id}/assets/../#{issue_id}/#{name}") |> response(404) == "Not found"
    assert conn |> get("/issues/#{issue_id}/assets/#{name}?list-type=2") |> response(404) == "Not found"
    assert conn |> get("/issues/#{issue_id}/assets/") |> response(404) == "Not found"

    {:ok, outsider} =
      Users.register_oauth_user(%{github_id: "gh_local_out", login: "local_out", email: "local_out@example.com"})

    assert conn |> log_in_user(outsider) |> get("/issues/#{issue_id}/assets/#{name}") |> response(404) == "Not found"
  end
end
