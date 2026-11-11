defmodule Rail.Issues.Actions.UploadFileTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Clients.R2
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Repo

  setup {Req.Test, :verify_on_exit!}

  setup do
    key = "Img#{System.unique_integer([:positive])}"

    {:ok, local} =
      Projects.create_project(system_scope(), %{
        name: "Rail-tracked",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        tracker: :local,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "Has a screenshot"})

    %{issue: issue, scope: user_scope(project_ids: [local.id])}
  end

  test "stores a screenshot under a name with no spaces, typed by its extension", %{
    issue: %Issue{id: issue_id} = issue,
    scope: scope
  } do
    Req.Test.expect(R2, fn conn ->
      assert %Plug.Conn{method: "PUT", request_path: "/r2_bucket/" <> path} = conn
      assert [^issue_id, name] = String.split(path, "/")
      assert name =~ ~r/\A[0-9a-f-]{36}-Screenshot-2026-11-10-at-14\.02\.11\.png\z/
      assert ["image/png"] = Plug.Conn.get_req_header(conn, "content-type")

      send(self(), {:put, name})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    result = Issues.upload_file(scope, issue, "Screenshot 2026-11-10 at 14.02.11.png", "PNG_BYTES")
    assert_received {:put, name}
    url = RailWeb.Endpoint.url() <> "/issues/#{issue_id}/assets/" <> name
    assert {:ok, ^url} = result

    # The name is one `get_asset/2` serves back.
    Req.Test.expect(R2, fn conn ->
      conn |> Plug.Conn.put_resp_content_type("image/png", nil) |> Plug.Conn.send_resp(200, "PNG_BYTES")
    end)

    assert {:ok, "image/png", "PNG_BYTES"} = Issues.get_asset(issue, name)
  end

  test "a name that cleans to nothing is stored as file", %{issue: issue, scope: scope} do
    Req.Test.expect(R2, fn conn ->
      assert conn.request_path =~ ~r/-file\z/
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:ok, _url} = Issues.upload_asset(issue, "", "image/png", "PNG_BYTES")
    assert {:error, :not_accepted} = Issues.upload_file(scope, issue, "", "PNG_BYTES")
  end

  test "a JPEG's type comes from its name, in any case", %{issue: issue, scope: scope} do
    Req.Test.expect(R2, fn conn ->
      assert ["image/jpeg"] = Plug.Conn.get_req_header(conn, "content-type")
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:ok, _url} = Issues.upload_file(scope, issue, "photo.JPG", "JPEG_BYTES")
  end

  test "a PDF is stored typed as one, under a name with no spaces", %{issue: %Issue{id: issue_id} = issue, scope: scope} do
    Req.Test.expect(R2, fn conn ->
      assert %Plug.Conn{method: "PUT", request_path: "/r2_bucket/" <> path} = conn
      assert [^issue_id, name] = String.split(path, "/")
      assert name =~ ~r/\A[0-9a-f-]{36}-Spec-v2\.pdf\z/
      assert ["application/pdf"] = Plug.Conn.get_req_header(conn, "content-type")
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:ok, _url} = Issues.upload_file(scope, issue, "Spec v2.pdf", "%PDF-1.7")
  end

  test "a page, an SVG or a Word file is not taken, and is never stored", %{issue: issue, scope: scope} do
    assert {:error, :not_accepted} = Issues.upload_file(scope, issue, "shot.html", "<script>alert(1)</script>")
    assert {:error, :not_accepted} = Issues.upload_file(scope, issue, "shot.svg", "<svg/>")
    assert {:error, :not_accepted} = Issues.upload_file(scope, issue, "notes.docx", "PK")
  end

  test "an issue Linear holds takes no uploads here", %{project: project} do
    linear =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_image_1",
        identifier: "IMG-1",
        title: "In Linear",
        state: :todo
      })
      |> Repo.insert!()

    assert {:error, :unsupported} = Issues.upload_file(system_scope(), linear, "shot.png", "PNG_BYTES")
  end

  test "someone who cannot open the project stores nothing", %{issue: issue} do
    assert {:error, :not_found} = Issues.upload_file(user_scope(project_ids: []), issue, "shot.png", "PNG_BYTES")
  end
end
