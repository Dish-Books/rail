defmodule RailWeb.Components.IssueUploadTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues
  alias Rail.Issues.Clients.R2
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Users

  setup {Req.Test, :verify_on_exit!}

  setup %{conn: conn} do
    key = "Upl#{System.unique_integer([:positive])}"

    {:ok, local} =
      Projects.create_project(system_scope(), %{
        name: "Takes files",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_#{key}", login: "user_#{key}", email: "#{key}@example.com"})

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [local.id]})
    {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "Has comments", description: "Old text"})
    stub(Issues, :link_pull_request, fn _scope, _issue -> {:ok, nil} end)

    %{conn: log_in_user(conn, user), issue: issue}
  end

  test "the comment box's upload is a hidden form the hook names, beside a textarea that keeps its own text", %{
    conn: conn,
    issue: %Issue{id: issue_id}
  } do
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")

    assert has_element?(view, "#issue-comment-form[data-file-drop]")

    assert has_element?(
             view,
             "#issue-comment-form-body-0[phx-hook='MarkdownPaste'][phx-update='ignore'][data-upload-form='issue-comment-form-upload']"
           )

    assert has_element?(view, "form#issue-comment-form-upload.hidden input[type='file']")
    refute has_element?(view, "#issue-comment-form-upload-error")
  end

  test "a screenshot goes up under the issue and comes back to the box that sent it", %{
    conn: conn,
    issue: %Issue{id: issue_id}
  } do
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")

    Req.Test.expect(R2, fn r2 ->
      assert "/" <> path = r2.request_path
      assert path =~ ~r"/#{issue_id}/[0-9a-f-]{36}-Screenshot-2026-11-23-at-14\.02\.11\.png\z"
      Plug.Conn.send_resp(r2, 200, "")
    end)

    image =
      file_input(view, "#issue-comment-form-upload", :file, [
        %{name: "Screenshot 2026-11-23 at 14.02.11.png", content: "PNG_BYTES", type: "image/png"}
      ])

    render_upload(image, "Screenshot 2026-11-23 at 14.02.11.png")
    render_async(view)

    assert_push_event(view, "upload_started", %{
      form: "issue-comment-form-upload",
      ref: ref,
      name: "Screenshot 2026-11-23 at 14.02.11.png"
    })

    assert_push_event(view, "insert_file", %{form: "issue-comment-form-upload", ref: ^ref, url: url, image: true})
    assert url =~ "/issues/#{issue_id}/assets/"
    refute has_element?(view, "#issue-comment-form-upload-error")
  end

  test "an image over 10 MB is refused under the comment box with the description's wording", %{
    conn: conn,
    issue: %Issue{id: issue_id}
  } do
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")

    image =
      file_input(view, "#issue-comment-form-upload", :file, [
        %{name: "huge.png", content: :binary.copy("x", 10_000_001), type: "image/png"}
      ])

    preflight_upload(image)
    view |> element("#issue-comment-form-upload") |> render_change(%{})

    assert_push_event(view, "upload_started", %{form: "issue-comment-form-upload", ref: ref, name: "huge.png"})
    assert_push_event(view, "upload_failed", %{form: "issue-comment-form-upload", ref: ^ref})

    assert has_element?(
             view,
             "form#issue-comment-form-upload:not(.hidden) #issue-comment-form-upload-error[role='alert']",
             "huge.png is over 10 MB, so it was not added."
           )

    refute has_element?(view, "#issue-description-editor-#{issue_id}-upload-error")
  end

  test "a file Rail does not take is refused under the comment box, and what was typed stays", %{
    conn: conn,
    issue: %Issue{id: issue_id}
  } do
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
    view |> element("#issue-comment-form") |> render_change(%{"body" => "Logs attached"})

    notes =
      file_input(view, "#issue-comment-form-upload", :file, [
        %{
          name: "notes.docx",
          content: "PK",
          type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        }
      ])

    preflight_upload(notes)
    view |> element("#issue-comment-form-upload") |> render_change(%{})

    assert_push_event(view, "upload_failed", %{form: "issue-comment-form-upload"})

    assert has_element?(
             view,
             "#issue-comment-form-upload-error",
             "notes.docx is not a PNG, JPEG, GIF, WebP or PDF file."
           )

    assert has_element?(view, "#issue-comment-form-body-0")
  end
end
