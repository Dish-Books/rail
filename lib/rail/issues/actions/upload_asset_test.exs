defmodule Rail.Issues.Actions.UploadAssetTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Projects
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock

  test "upload_asset/4 uploads binary data using workspace token" do
    scope = Scope.for_system()

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Upload Asset Project",
        github_repo: "org/upload-asset",
        github_installation_id: 5201,
        linear_workspace: %{
          name: "Upload Asset Workspace",
          external_id: "lin_ws_upload_asset",
          token: "lin_api_token_upload_asset",
          webhook_secret: "whsec_upload_asset"
        },
        linear_team_id: "team_upload_asset",
        linear_team_key: "UPA",
        default_branch: "main",
        clone_path: "/tmp/repos/upload-asset"
      })

    LinearMock.mock_file_upload_success(
      upload_url: "https://api.linear.app/upload/asset_111",
      asset_url: "https://uploads.linear.app/asset_111/screenshot.png",
      asset_id: "asset_111"
    )

    binary_data = "PNG_CONTENT"

    assert {:ok,
            %{
              asset_id: "asset_111",
              asset_url: "https://uploads.linear.app/asset_111/screenshot.png"
            }} = Issues.upload_asset(project, "screenshot.png", "image/png", binary_data)

    LinearMock.mock_file_upload_success(
      upload_url: "https://api.linear.app/upload/asset_222",
      asset_url: "https://uploads.linear.app/asset_222/frame.png",
      asset_id: "asset_222"
    )

    assert {:ok, %{asset_id: "asset_222"}} =
             Issues.upload_asset(project, "frame.png", "image/png", binary_data)

    LinearMock.mock_file_upload_success(
      upload_url: "https://api.linear.app/upload/asset_333",
      asset_url: "https://uploads.linear.app/asset_333/ws.png",
      asset_id: "asset_333"
    )

    assert {:ok, %{asset_id: "asset_333"}} =
             Issues.upload_asset(project.linear_workspace, "ws.png", "image/png", binary_data)
  end

  test "upload_asset/4 returns error when the project has no workspace" do
    {:ok, project} =
      Projects.create_project(Scope.for_system(), %{
        name: "Upload Asset No Workspace",
        github_repo: "org/upload-asset-none",
        github_installation_id: 5202,
        linear_team_id: "team_upload_asset_none",
        linear_team_key: "UPN",
        default_branch: "main",
        clone_path: "/tmp/repos/upload-asset-none"
      })

    assert {:error, :no_workspace_token} =
             Issues.upload_asset(project, "file.png", "image/png", "DATA")
  end
end
