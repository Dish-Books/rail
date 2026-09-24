defmodule Rail.Issues.Actions.UploadAssetTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Projects
  alias Rail.Scope

  test "upload_asset/4 uploads to Linear and returns the asset URL, for a project or its workspace", %{project: project} do
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

  test "upload_asset/4 returns an error when Linear gives nowhere to upload to", %{project: project} do
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
