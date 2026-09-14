defmodule Rail.Issues.Actions.GetAssetTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Repo

  setup do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Get Asset Project",
        github_repo: "org/get-asset",
        github_installation_id: 5301,
        linear_workspace: %{
          name: "Get Asset Workspace",
          external_id: "lin_ws_get_asset",
          token: "lin_api_token_get_asset",
          webhook_secret: "whsec_get_asset"
        },
        linear_team_key: "GAS",
        default_branch: "main",
        clone_path: "/tmp/repos/get-asset",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_get_asset", "identifier" => "GAS-1", "title" => "Get Asset Issue"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Get Asset Issue"})

    %{issue: Repo.preload(issue, :project)}
  end

  test "get_asset/2 fetches the file as the workspace that can read it", %{issue: issue} do
    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/ws/img/screenshot.png"
      assert ["Bearer lin_api_token_get_asset"] = Plug.Conn.get_req_header(conn, "authorization")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, "PNG_BYTES")
    end)

    assert {:ok, "image/png; charset=utf-8", "PNG_BYTES"} =
             Issues.get_asset(issue, "ws/img/screenshot.png")
  end

  test "get_asset/2 falls back to bytes when Linear says nothing about the type", %{issue: issue} do
    Req.Test.expect(Rail.Linear, fn conn ->
      conn
      |> Plug.Conn.delete_resp_header("content-type")
      |> Plug.Conn.send_resp(200, "BYTES")
    end)

    assert {:ok, "application/octet-stream", "BYTES"} = Issues.get_asset(issue, "ws/img/typeless")
  end

  test "get_asset/2 says so when Linear will not serve the file", %{issue: issue} do
    Req.Test.expect(Rail.Linear, fn conn -> Plug.Conn.send_resp(conn, 403, "Denied") end)

    assert {:error, {:linear_api_error, 403, "Denied"}} = Issues.get_asset(issue, "ws/img/gone.png")
  end

  test "get_asset/2 has nothing to fetch with when the project has no workspace" do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Get Asset No Workspace",
        github_repo: "org/get-asset-none",
        github_installation_id: 5302,
        linear_team_key: "GAN",
        default_branch: "main",
        clone_path: "/tmp/repos/get-asset-none"
      })

    issue = %Issue{project: project}

    assert {:error, :no_workspace_token} = Issues.get_asset(issue, "ws/img/screenshot.png")
  end
end
