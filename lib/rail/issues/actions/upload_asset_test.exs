defmodule Rail.Issues.Actions.UploadAssetTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Users
  alias RailTest.Mocks.Linear, as: LinearMock

  test "upload_asset/4 uploads binary data using workspace token" do
    scope = Scope.for_system()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(scope, %{
        name: "Upload Asset Workspace",
        external_id: "lin_ws_upload_asset",
        token: "lin_api_token_upload_asset",
        webhook_secret: "whsec_upload_asset"
      })

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Upload Asset Project",
        github_repo: "org/upload-asset",
        github_installation_id: 5201,
        linear_workspace_id: workspace.id,
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
            }} = Issues.upload_asset(scope, "screenshot.png", "image/png", binary_data)

    LinearMock.mock_file_upload_success(
      upload_url: "https://api.linear.app/upload/asset_222",
      asset_url: "https://uploads.linear.app/asset_222/frame.png",
      asset_id: "asset_222"
    )

    assert {:ok, %{asset_id: "asset_222"}} =
             Issues.upload_asset(scope, project, "frame.png", "image/png", binary_data)

    LinearMock.mock_file_upload_success(
      upload_url: "https://api.linear.app/upload/asset_333",
      asset_url: "https://uploads.linear.app/asset_333/ws.png",
      asset_id: "asset_333"
    )

    assert {:ok, %{asset_id: "asset_333"}} =
             Issues.upload_asset(scope, workspace, "ws.png", "image/png", binary_data)
  end

  test "upload_asset/4 works with user scope" do
    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Upload Asset User Workspace",
        external_id: "lin_ws_upload_user",
        token: "lin_api_token_upload_user",
        webhook_secret: "whsec_upload_user"
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_upload_asset",
        login: "upload_asset_user",
        email: "upload_asset@example.com"
      })

    scope = Scope.for_user(user)

    LinearMock.mock_file_upload_success(
      upload_url: "https://api.linear.app/upload/asset_user",
      asset_url: "https://uploads.linear.app/asset_user/file.png",
      asset_id: "asset_user"
    )

    assert {:ok, %{asset_id: "asset_user"}} =
             Issues.upload_asset(scope, "file.png", "image/png", "DATA")
  end

  test "upload_asset/4 returns error when no workspace token available" do
    scope = Scope.for_system()

    assert {:error, :no_workspace_token} =
             Issues.upload_asset(scope, "file.png", "image/png", "DATA")
  end

  test "upload_asset/4 returns :not_authorized for nil scope" do
    assert {:error, :not_authorized} = Issues.upload_asset(nil, "file.png", "image/png", "DATA")
  end
end
