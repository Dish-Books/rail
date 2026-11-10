defmodule Rail.Issues.Actions.UploadAssetTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Clients.R2
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Scope

  test "upload_asset/4 uploads to Linear and returns the asset URL", %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "fileUpload" => %{
            "success" => true,
            "uploadFile" => %{
              "uploadUrl" => "https://api.linear.app/upload/screenshot.png",
              "assetUrl" => "https://uploads.linear.app/screenshot.png",
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

    assert {:ok, "https://uploads.linear.app/screenshot.png"} =
             Issues.upload_asset(%Issue{project: project}, "screenshot.png", "image/png", "PNG_CONTENT")
  end

  test "upload_asset/4 returns an error when Linear gives nowhere to upload to", %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"fileUpload" => %{"success" => false}}})
    end)

    assert {:error, {:linear_mutation_failed, "fileUpload"}} =
             Issues.upload_asset(%Issue{project: project}, "file.png", "image/png", "DATA")
  end

  test "upload_asset/4 returns error when the project has no workspace" do
    {:ok, project} =
      Projects.create_project(Scope.for_system(), %{
        name: "Upload Asset No Workspace",
        github_repo: "org/upload-asset-none",
        github_installation_id: 5202,
        key: "UPN",
        default_branch: "main",
        clone_path: "/tmp/repos/upload-asset-none"
      })

    assert {:error, :no_workspace_token} =
             Issues.upload_asset(%Issue{project: project}, "file.png", "image/png", "DATA")
  end

  test "upload_asset/4 has nowhere to put a file for a GitHub project", %{github_project: project} do
    assert {:error, :unsupported} =
             Issues.upload_asset(%Issue{tracker: :github, project: project}, "shot.png", "image/png", <<1>>)
  end

  test "upload_asset/4 puts a Rail-tracked issue's file in R2 under its id and returns its address on Rail", %{
    project: project
  } do
    issue = %Issue{id: "iss_upload_local", tracker: :local, project: %{project | tracker: :local}}

    Req.Test.expect(R2, fn conn ->
      assert %Plug.Conn{
               method: "PUT",
               host: "r2_account_id.r2.cloudflarestorage.com",
               request_path: "/r2_bucket/iss_upload_local/" <> name
             } = conn

      assert name =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-RAIL-1-demo\.webm\z/
      assert ["video/webm"] = Plug.Conn.get_req_header(conn, "content-type")
      assert ["AWS4-HMAC-SHA256 Credential=r2_access_key_id/" <> scope] = Plug.Conn.get_req_header(conn, "authorization")
      assert scope =~ ~r"\A\d{8}/auto/s3/aws4_request,"
      assert {:ok, "WEBM_BYTES", conn} = Plug.Conn.read_body(conn)

      send(self(), {:put, name})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    result = Issues.upload_asset(issue, "RAIL-1-demo.webm", "video/webm", "WEBM_BYTES")
    assert_received {:put, name}
    url = RailWeb.Endpoint.url() <> "/issues/iss_upload_local/assets/" <> name
    assert {:ok, ^url} = result
  end

  test "upload_asset/4 gives no address when R2 refuses the file", %{project: project} do
    issue = %Issue{id: "iss_upload_refused", tracker: :local, project: %{project | tracker: :local}}

    Req.Test.expect(R2, fn conn -> Plug.Conn.send_resp(conn, 403, "AccessDenied") end)

    assert {:error, {:r2_error, 403, "AccessDenied"}} =
             Issues.upload_asset(issue, "RAIL-1-chips.png", "image/png", "PNG_BYTES")

    Req.Test.expect(R2, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, %Req.TransportError{reason: :econnrefused}} =
             Issues.upload_asset(issue, "RAIL-1-chips.png", "image/png", "PNG_BYTES")
  end
end
