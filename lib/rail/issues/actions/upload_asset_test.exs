defmodule Rail.Issues.Actions.UploadAssetTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User
  alias RailTest.Mocks.Linear, as: LinearMock

  test "upload_asset/4 uploads binary data using workspace token" do
    workspace = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: workspace.id})

    LinearMock.mock_file_upload_success(
      upload_url: "https://api.linear.app/upload/asset_111",
      asset_url: "https://uploads.linear.app/asset_111/screenshot.png",
      asset_id: "asset_111"
    )

    scope = Scope.for_system()
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
    _workspace = Repo.insert!(LinearWorkspace.factory())
    user = Repo.insert!(User.factory())
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
