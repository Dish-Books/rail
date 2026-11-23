defmodule Rail.Issues.Actions.UploadAssetTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Clients.R2
  alias Rail.Issues.Schemas.Issue

  test "upload_asset/4 puts an issue's file in R2 under its id and returns its address on Rail", %{
    project: project
  } do
    issue = %Issue{id: "iss_upload_local", project: project}

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
    issue = %Issue{id: "iss_upload_refused", project: project}

    Req.Test.expect(R2, fn conn -> Plug.Conn.send_resp(conn, 403, "AccessDenied") end)

    assert {:error, {:r2_error, 403, "AccessDenied"}} =
             Issues.upload_asset(issue, "RAIL-1-chips.png", "image/png", "PNG_BYTES")

    Req.Test.expect(R2, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, %Req.TransportError{reason: :econnrefused}} =
             Issues.upload_asset(issue, "RAIL-1-chips.png", "image/png", "PNG_BYTES")
  end
end
