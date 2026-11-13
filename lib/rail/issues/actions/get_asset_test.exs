defmodule Rail.Issues.Actions.GetAssetTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Clients.R2
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Repo

  setup %{project: project} do
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

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Issue", description: "Get Asset Issue"})

    %{issue: Repo.preload(issue, :project)}
  end

  test "get_asset/2 fetches the file as the workspace that can read it", %{issue: issue} do
    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/ws/img/screenshot.png"
      assert ["Bearer lin_api_test_seed"] = Plug.Conn.get_req_header(conn, "authorization")

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
        key: "GAN",
        default_branch: "main",
        clone_path: "/tmp/repos/get-asset-none"
      })

    issue = %Issue{project: project}

    assert {:error, :no_workspace_token} = Issues.get_asset(issue, "ws/img/screenshot.png")
  end

  test "get_asset/2 has nothing to fetch for a GitHub issue", %{github_project: project} do
    assert {:error, :unsupported} = Issues.get_asset(github_issue(project), "any/path.png")
  end

  test "get_asset/2 reads a Rail-tracked issue's file from R2 under that issue's id", %{project: project} do
    issue = %Issue{id: "iss_get_local", tracker: :local, project: %{project | tracker: :local}}
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
    issue = %Issue{id: "iss_get_refused", tracker: :local, project: %{project | tracker: :local}}
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
    issue = %Issue{id: "iss_get_missing", tracker: :local, project: %{project | tracker: :local}}
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
