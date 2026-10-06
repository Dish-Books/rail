defmodule Rail.Triage.Actions.GetTriageImageTest do
  use Rail.DataCase, async: true

  alias Rail.Triage
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread

  setup do
    %{project: project} = triage_project()
    %{workspace: workspace, channel: channel} = connect_slack_channel(project)

    stub_slack(files: %{"/files-pri/T1-F_SHOT/button.png" => {"image/png", "png-bytes"}})

    {:ok, %Thread{id: thread_id}} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{
          "subtype" => "file_share",
          "text" => "this button is broken",
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

    %{project: project, message_id: message_id}
  end

  test "a scope that can see the thread's project gets the image's bytes and its stored type", %{
    project: project,
    message_id: message_id
  } do
    for scope <- [user_scope(project_ids: [project.id]), user_scope(admin: true), system_scope()] do
      assert {:ok, "image/png", "png-bytes"} = Triage.get_triage_image(scope, message_id, "F_SHOT")
    end
  end

  test "a scope that cannot see the thread's project gets nothing", %{message_id: message_id} do
    assert {:error, :not_found} = Triage.get_triage_image(user_scope(project_ids: ["prj_other"]), message_id, "F_SHOT")
    assert {:error, :not_found} = Triage.get_triage_image(user_scope(), message_id, "F_SHOT")
  end

  test "a file Slack withheld is not found and Slack is never asked", %{message_id: message_id} do
    test = self()

    Req.Test.stub(Rail.Slack, fn conn ->
      send(test, :requested)
      Plug.Conn.send_resp(conn, 200, "bytes")
    end)

    assert {:error, :not_found} = Triage.get_triage_image(system_scope(), message_id, "F_HIDDEN")
    refute_received :requested
  end

  test "a file the message did not come with is not found", %{message_id: message_id} do
    assert {:error, :not_found} = Triage.get_triage_image(system_scope(), message_id, "F_OTHER")
    assert {:error, :not_found} = Triage.get_triage_image(system_scope(), "tms_missing", "F_SHOT")
  end

  test "an image Slack will not serve is an error", %{message_id: message_id} do
    assert {:error, {:slack_error, :not_an_image}} = Triage.get_triage_image(system_scope(), message_id, "F_GONE")

    Req.Test.stub(Rail.Slack, &Plug.Conn.send_resp(&1, 404, "gone"))

    assert {:error, {:slack_error, 404}} = Triage.get_triage_image(system_scope(), message_id, "F_SHOT")
  end
end
