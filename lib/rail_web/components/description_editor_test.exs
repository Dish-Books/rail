defmodule RailWeb.Components.DescriptionEditorTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues
  alias Rail.Issues.Clients.R2
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Users

  setup {Req.Test, :verify_on_exit!}

  setup %{conn: conn} do
    key = "Dsc#{System.unique_integer([:positive])}"

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

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_#{key}", login: "user_#{key}", email: "#{key}@example.com"})

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [local.id]})
    {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "Has a description", description: "Old *text*"})
    stub(Issues, :link_pull_request, fn _scope, _issue -> {:ok, nil} end)

    %{conn: log_in_user(conn, user), issue: issue, local: local}
  end

  test "carries the issue's id and saved markdown for the hook, with the save notice rendered hidden", %{
    conn: conn,
    issue: %Issue{id: issue_id}
  } do
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
    editor = "#issue-description-editor-#{issue_id}"

    assert has_element?(
             view,
             "#issue-description-#{issue_id}[phx-hook='IssueDescription'][phx-update='ignore'][data-issue-id='#{issue_id}'][data-saved='Old *text*']"
           )

    assert has_element?(view, "#{editor}-notice.hidden[role='alert']", "Couldn't save the description")
    assert has_element?(view, "#{editor}-retry", "Retry now")
    assert has_element?(view, "#issue-description-#{issue_id} em", "text")
  end

  test "an issue with no description carries an empty saved text", %{conn: conn, local: local} do
    {:ok, %Issue{id: issue_id}} = Issues.create_issue(system_scope(), local, %{title: "Nothing written"})
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")

    assert has_element?(view, "#issue-description-#{issue_id}[data-saved='']", "Add description...")
  end

  test "a save replies that it went through, and the new markdown reaches the container", %{
    conn: conn,
    issue: %Issue{id: issue_id}
  } do
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")

    # The hook pushes to the component that holds it.
    view
    |> with_target("#issue-description-editor-#{issue_id}")
    |> render_hook("save_description", %{"description" => "- [ ] Typed in place"})

    assert_reply(view, %{ok: true})
    assert %Issue{description: "- [ ] Typed in place"} = Repo.get!(Issue, issue_id)
    assert has_element?(view, "#issue-description-#{issue_id}[data-saved='- [ ] Typed in place']")
  end

  test "a save the action refuses replies that it did not, and so does a malformed one", %{
    conn: conn,
    issue: %Issue{id: issue_id} = issue
  } do
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
    Repo.delete!(issue)

    editor = with_target(view, "#issue-description-editor-#{issue_id}")
    render_hook(editor, "save_description", %{"description" => "Lost"})
    assert_reply(view, %{ok: false})

    render_hook(editor, "save_description", %{"text" => "Lost"})
    assert_reply(view, %{ok: false})
  end

  test "a screenshot goes up under its ref and comes back as an address Rail serves", %{
    conn: conn,
    issue: %Issue{id: issue_id}
  } do
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")

    Req.Test.expect(R2, fn r2 ->
      assert ["image/png"] = Plug.Conn.get_req_header(r2, "content-type")
      Plug.Conn.send_resp(r2, 200, "")
    end)

    image =
      file_input(view, "#issue-description-editor-#{issue_id}-upload", :image, [
        %{name: "Screenshot 2026-11-10 at 14.02.11.png", content: :binary.copy("P", 1000), type: "image/png"}
      ])

    render_upload(image, "Screenshot 2026-11-10 at 14.02.11.png", 50)
    render_upload(image, "Screenshot 2026-11-10 at 14.02.11.png", 50)
    render_async(view)

    assert_push_event(view, "upload_started", %{ref: ref, name: "Screenshot 2026-11-10 at 14.02.11.png"})
    assert_push_event(view, "insert_image", %{ref: ^ref, url: url})
    refute has_element?(view, "#issue-description-editor-#{issue_id}-upload-error")

    %URI{path: path} = URI.parse(url)

    Req.Test.expect(R2, fn r2 ->
      r2 |> Plug.Conn.put_resp_content_type("image/png", nil) |> Plug.Conn.send_resp(200, :binary.copy("P", 1000))
    end)

    assert conn |> get(path) |> response(200) == :binary.copy("P", 1000)
  end

  test "an image too large is refused for its ref, with the reason under the description", %{
    conn: conn,
    issue: %Issue{id: issue_id}
  } do
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")

    image =
      file_input(view, "#issue-description-editor-#{issue_id}-upload", :image, [
        %{name: "huge.png", content: :binary.copy("x", 10_000_001), type: "image/png"}
      ])

    assert {:ok, %{errors: errors}} = preflight_upload(image)
    assert [{ref, [:too_large]}] = Map.to_list(errors)
    view |> element("#issue-description-editor-#{issue_id}-upload") |> render_change(%{})
    assert_push_event(view, "upload_started", %{ref: ^ref, name: "huge.png"})
    assert_push_event(view, "upload_failed", %{ref: ^ref})
    assert has_element?(view, "#issue-description-editor-#{issue_id}-upload-error", "huge.png is over 10 MB")
  end

  test "a file that is not an image is refused for its ref", %{conn: conn, issue: %Issue{id: issue_id}} do
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")

    page =
      file_input(view, "#issue-description-editor-#{issue_id}-upload", :image, [
        %{name: "page.html", content: "<script></script>", type: "text/html"}
      ])

    preflight_upload(page)
    view |> element("#issue-description-editor-#{issue_id}-upload") |> render_change(%{})

    assert_push_event(view, "upload_started", %{ref: ref, name: "page.html"})
    assert_push_event(view, "upload_failed", %{ref: ^ref})
    assert has_element?(view, "#issue-description-editor-#{issue_id}-upload-error", "page.html is not a PNG")
  end

  test "a sixth image at once is refused for its ref", %{conn: conn, issue: %Issue{id: issue_id}} do
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")

    files = for n <- 1..6, do: %{name: "shot-#{n}.png", content: "PNG_BYTES", type: "image/png"}
    image = file_input(view, "#issue-description-editor-#{issue_id}-upload", :image, files)
    preflight_upload(image)
    view |> element("#issue-description-editor-#{issue_id}-upload") |> render_change(%{})

    assert_push_event(view, "upload_started", %{ref: ref, name: "shot-6.png"})
    assert_push_event(view, "upload_failed", %{ref: ^ref})
    assert has_element?(view, "#issue-description-editor-#{issue_id}-upload-error", "Up to 5 images")
  end

  test "an upload R2 refuses, and one whose task crashes, each fail for their ref with the reason", %{
    conn: conn,
    issue: %Issue{id: issue_id}
  } do
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
    Req.Test.expect(R2, fn r2 -> Plug.Conn.send_resp(r2, 500, "InternalError") end)

    refused =
      file_input(view, "#issue-description-editor-#{issue_id}-upload", :image, [
        %{name: "refused.png", content: "PNG_BYTES", type: "image/png"}
      ])

    render_upload(refused, "refused.png")
    render_async(view)
    assert_push_event(view, "upload_started", %{ref: refused_ref, name: "refused.png"})
    assert_push_event(view, "upload_failed", %{ref: ^refused_ref})
    assert has_element?(view, "#issue-description-editor-#{issue_id}-upload-error", "Couldn't upload refused.png")

    stub(Issues, :upload_image, fn _scope, _issue, _name, _data -> raise "R2 went away" end)

    crashed =
      file_input(view, "#issue-description-editor-#{issue_id}-upload", :image, [
        %{name: "crashed.png", content: "PNG_BYTES", type: "image/png"}
      ])

    render_upload(crashed, "crashed.png")
    render_async(view)
    assert_push_event(view, "upload_started", %{ref: crashed_ref, name: "crashed.png"})
    assert_push_event(view, "upload_failed", %{ref: ^crashed_ref})
    assert has_element?(view, "#issue-description-editor-#{issue_id}-upload-error", "Couldn't upload crashed.png")
  end

  test "an image whose name is not one Rail serves is refused with the reason", %{
    conn: conn,
    issue: %Issue{id: issue_id}
  } do
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")

    image =
      file_input(view, "#issue-description-editor-#{issue_id}-upload", :image, [
        %{name: "shot", content: "PNG_BYTES", type: "image/png"}
      ])

    render_upload(image, "shot")
    render_async(view)
    assert_push_event(view, "upload_started", %{ref: ref, name: "shot"})
    assert_push_event(view, "upload_failed", %{ref: ^ref})
    assert has_element?(view, "#issue-description-editor-#{issue_id}-upload-error", "shot is not a PNG")
  end
end
