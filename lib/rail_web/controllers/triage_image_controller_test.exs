defmodule RailWeb.TriageImageControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Triage
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users

  setup %{conn: conn} do
    %{project: project} = triage_project()
    %{workspace: workspace, channel: channel} = connect_slack_channel(project)
    stub_slack(files: %{"/files-pri/T1-F_SHOT/button.png" => {"image/png", "png-bytes"}})

    {:ok, %Thread{id: thread_id}} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{
          "subtype" => "file_share",
          "files" => [
            %{
              "id" => "F_SHOT",
              "name" => "button.png",
              "mimetype" => "image/png",
              "url_private" => "https://files.slack.com/files-pri/T1-F_SHOT/button.png"
            },
            %{
              "id" => "F_GONE",
              "name" => "gone.png",
              "mimetype" => "image/png",
              "url_private" => "https://files.slack.com/files-pri/T1-F_GONE/gone.png"
            },
            %{"id" => "F_HIDDEN", "file_access" => "check_file_info"}
          ]
        })
      )

    {:ok, %Thread{messages: [%Message{id: message_id}]}} = Triage.get_triage_thread(system_scope(), thread_id)

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_triage_image", login: "triage_image", email: "ti@example.com"})

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})

    %{conn: log_in_user(conn, user), message_id: message_id}
  end

  test "a teammate with the project gets the image, typed as stored and never run as a page", %{
    conn: conn,
    message_id: message_id
  } do
    conn = get(conn, ~p"/triage/messages/#{message_id}/images/F_SHOT")

    assert response(conn, 200) == "png-bytes"
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "cache-control") == ["private, max-age=3600"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-security-policy") == ["sandbox"]
  end

  test "a stranger is sent to sign in rather than served", %{message_id: message_id} do
    conn = get(build_conn(), ~p"/triage/messages/#{message_id}/images/F_SHOT")

    assert redirected_to(conn) =~ "/sign-in"
  end

  test "a teammate without the project gets nothing, while an admin is served", %{
    conn: conn,
    message_id: message_id
  } do
    {:ok, outsider} =
      Users.register_oauth_user(%{github_id: "gh_outsider", login: "outsider", email: "outsider@example.com"})

    {:ok, outsider} = Users.update_user(system_scope(), outsider, %{project_ids: ["prj_other"]})

    assert conn |> log_in_user(outsider) |> get(~p"/triage/messages/#{message_id}/images/F_SHOT") |> response(404) ==
             "Not found"

    {:ok, admin} =
      Users.register_oauth_user(%{github_id: "gh_image_admin", login: "image_admin", email: "a@x.com", admin: true})

    assert conn |> log_in_user(admin) |> get(~p"/triage/messages/#{message_id}/images/F_SHOT") |> response(200) ==
             "png-bytes"
  end

  test "an image Slack will not serve and a file Slack withheld are not found", %{conn: conn, message_id: message_id} do
    assert conn |> get(~p"/triage/messages/#{message_id}/images/F_GONE") |> response(404) == "Not found"
    assert conn |> get(~p"/triage/messages/#{message_id}/images/F_HIDDEN") |> response(404) == "Not found"
  end
end
