defmodule RailWeb.IssueAssetControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Issues
  alias Rail.Projects
  alias Rail.Users

  setup %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issue_asset",
        login: "issue_asset_user",
        email: "issue_asset_user@example.com"
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Issue Asset Project",
        github_repo: "org/issue-asset",
        github_installation_id: 47_010,
        linear_workspace: %{
          name: "Issue Asset Workspace",
          external_id: "lin_ws_issue_asset",
          token: "lin_api_token_issue_asset",
          webhook_secret: "whsec_issue_asset"
        },
        linear_team_key: "IAS",
        default_branch: "main",
        clone_path: "/tmp/repos/issue-asset",
        linear_state_ids: %{"triage" => "st_triage"}
      })

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
end
