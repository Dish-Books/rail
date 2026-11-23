defmodule Rail.Issues.Actions.GetAssetTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Clients.R2
  alias Rail.Issues.Schemas.Issue

  test "get_asset/2 reads an issue's file from R2 under that issue's id", %{project: project} do
    issue = %Issue{id: "iss_get_local", project: project}
    name = "#{Ecto.UUID.generate()}-RAIL-1-chips.png"

    Req.Test.expect(R2, fn conn ->
      assert %Plug.Conn{method: "GET", request_path: "/r2_bucket/iss_get_local/" <> ^name} = conn
      assert ["AWS4-HMAC-SHA256 Credential=r2_access_key_id/" <> _scope] = Plug.Conn.get_req_header(conn, "authorization")

      conn
      |> Plug.Conn.put_resp_content_type("image/png", nil)
      |> Plug.Conn.send_resp(200, "PNG_BYTES")
    end)

    assert {:ok, "image/png", "PNG_BYTES"} = Issues.get_asset(issue, name)
  end

  test "get_asset/2 asks R2 for no name but one an upload writes", %{project: project} do
    issue = %Issue{id: "iss_get_refused", project: project}
    uuid = Ecto.UUID.generate()

    for name <- [
          "",
          "..",
          "../iss_other/#{uuid}-shot.png",
          "#{uuid}-shot.png/../../iss_other/#{uuid}-shot.png",
          "iss_other/#{uuid}-shot.png",
          "#{uuid}-shot.png?list-type=2",
          "#{uuid}-",
          "shot.png",
          "#{String.upcase(uuid)}-shot.png"
        ] do
      assert {:error, :not_found} = Issues.get_asset(issue, name)
    end
  end

  test "get_asset/2 says when R2 has no such file, or fails to answer", %{project: project} do
    issue = %Issue{id: "iss_get_missing", project: project}
    name = "#{Ecto.UUID.generate()}-RAIL-1-demo.webm"

    Req.Test.expect(R2, &Plug.Conn.send_resp(&1, 404, "NoSuchKey"))
    assert {:error, :not_found} = Issues.get_asset(issue, name)

    Req.Test.expect(R2, &Plug.Conn.send_resp(&1, 500, "InternalError"))
    assert {:error, {:r2_error, 500, "InternalError"}} = Issues.get_asset(issue, name)

    Req.Test.expect(R2, fn conn ->
      conn
      |> Plug.Conn.delete_resp_header("content-type")
      |> Plug.Conn.send_resp(200, "BYTES")
    end)

    assert {:ok, "application/octet-stream", "BYTES"} = Issues.get_asset(issue, name)

    Req.Test.expect(R2, &Req.Test.transport_error(&1, :timeout))
    assert {:error, %Req.TransportError{reason: :timeout}} = Issues.get_asset(issue, name)
  end
end
