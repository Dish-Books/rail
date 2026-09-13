defmodule Rail.Issues.Actions.UploadAssetTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Projects
  alias Rail.Scope

  test "upload_asset/4 uploads to Linear and returns the asset URL, for a project or its workspace" do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(Scope.for_system(), %{
        name: "Upload Asset Project",
        github_repo: "org/upload-asset",
        github_installation_id: 5201,
        linear_workspace: %{
          name: "Upload Asset Workspace",
          external_id: "lin_ws_upload_asset",
          token: "lin_api_token_upload_asset",
          webhook_secret: "whsec_upload_asset"
        },
        linear_team_key: "UPA",
        default_branch: "main",
        clone_path: "/tmp/repos/upload-asset"
      })

    for {target, name} <- [{project, "screenshot.png"}, {project.linear_workspace, "ws.png"}] do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "fileUpload" => %{
              "success" => true,
              "uploadFile" => %{
                "uploadUrl" => "https://api.linear.app/upload/#{name}",
                "assetUrl" => "https://uploads.linear.app/#{name}",
                "headers" => [%{"key" => "Content-Type", "value" => "image/png"}]
              }
            }
          }
        })
      end)

      Req.Test.expect(Rail.Linear, fn conn ->
        assert conn.method == "PUT"
        Plug.Conn.send_resp(conn, 200, "")
      end)

      asset_url = "https://uploads.linear.app/#{name}"
      assert {:ok, ^asset_url} = Issues.upload_asset(target, name, "image/png", "PNG_CONTENT")
    end
  end

  test "upload_asset/4 returns an error when Linear gives nowhere to upload to" do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(Scope.for_system(), %{
        name: "Upload Asset Refused",
        github_repo: "org/upload-asset-refused",
        github_installation_id: 5203,
        linear_workspace: %{
          name: "Upload Asset Refused Workspace",
          external_id: "lin_ws_upload_asset_refused",
          token: "lin_api_token_upload_asset",
          webhook_secret: "whsec_upload_asset"
        },
        linear_team_key: "UPR",
        default_branch: "main",
        clone_path: "/tmp/repos/upload-asset-refused"
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"fileUpload" => %{"success" => false}}})
    end)

    assert {:error, {:linear_mutation_failed, "fileUpload"}} =
             Issues.upload_asset(project, "file.png", "image/png", "DATA")
  end

  test "upload_asset/4 returns error when the project has no workspace" do
    {:ok, project} =
      Projects.create_project(Scope.for_system(), %{
        name: "Upload Asset No Workspace",
        github_repo: "org/upload-asset-none",
        github_installation_id: 5202,
        linear_team_key: "UPN",
        default_branch: "main",
        clone_path: "/tmp/repos/upload-asset-none"
      })

    assert {:error, :no_workspace_token} = Issues.upload_asset(project, "file.png", "image/png", "DATA")
  end
end
