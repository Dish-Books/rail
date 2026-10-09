defmodule Rail.Triage.Actions.BackfillSlackWorkspaceTest do
  use Rail.DataCase, async: true

  import ExUnit.CaptureLog

  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Triage
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread

  setup %{project: project} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "triage")
    %{workspace: workspace, channel: channel} = connect_slack_channel(project)
    now = System.os_time(:second)

    # Posted after the channel was connected, which is as far back as a backfill reads.
    %{workspace: workspace, channel: channel, heard: "#{now + 60}.000100", missed: "#{now + 120}.000200"}
  end

  test "files what was posted since the newest thread it has, oldest first, and schedules a pass for each", %{
    workspace: workspace,
    channel: %{external_id: channel_id} = channel,
    heard: heard,
    missed: missed
  } do
    {:ok, %Thread{}} = Triage.handle_slack_event(workspace, slack_message_event(channel, %{"ts" => heard}))
    assert_receive {:triage_scheduled, _heard_thread, 15_000}
    later = "#{System.os_time(:second) + 180}.000300"
    test = self()

    Req.Test.stub(Rail.Slack, fn conn ->
      case conn.request_path do
        "/api/users.info" ->
          Req.Test.json(conn, %{"ok" => true, "user" => %{"real_name" => "Priya"}})

        "/api/conversations.history" ->
          send(test, {:history, conn.query_params})

          Req.Test.json(conn, %{
            "ok" => true,
            "messages" => [
              %{"type" => "message", "user" => "U_PRIYA", "text" => "Second", "ts" => later},
              %{"type" => "message", "subtype" => "channel_join", "user" => "U_NEW", "ts" => "#{missed}9"},
              %{"type" => "message", "user" => "U_PRIYA", "text" => "First", "ts" => missed}
            ]
          })
      end
    end)

    assert [^missed, ^later] = Triage.backfill_slack_workspace(workspace)
    assert_received {:history, %{"channel" => ^channel_id, "oldest" => ^heard}}

    assert %Message{thread: %Thread{id: first, status: :triaging, external_id: ^missed}} =
             Message |> Repo.get_by(text: "First") |> Repo.preload(:thread)

    assert_received {:triage_scheduled, ^first, 15_000}
    assert %Message{thread_id: second} = Repo.get_by(Message, text: "Second")
    assert_received {:triage_scheduled, ^second, 15_000}
    assert 3 = Repo.aggregate(Message, :count)
  end

  test "a message delivered both live and by backfill is filed once and triaged once", %{
    workspace: workspace,
    channel: channel,
    heard: heard,
    missed: missed
  } do
    Req.Test.stub(Rail.Slack, fn conn ->
      case conn.request_path do
        "/api/users.info" ->
          Req.Test.json(conn, %{"ok" => true, "user" => %{"real_name" => "Priya"}})

        "/api/conversations.history" ->
          Req.Test.json(conn, %{
            "ok" => true,
            "messages" => [
              %{"type" => "message", "user" => "U_PRIYA", "text" => "Late", "ts" => missed},
              %{"type" => "message", "user" => "U_PRIYA", "text" => "Live", "ts" => heard}
            ]
          })
      end
    end)

    # Live first, then found again by a backfill.
    {:ok, %Thread{id: live}} =
      Triage.handle_slack_event(workspace, slack_message_event(channel, %{"text" => "Live", "ts" => heard}))

    assert_receive {:triage_scheduled, ^live, 15_000}
    assert [^missed] = Triage.backfill_slack_workspace(workspace)
    refute_received {:triage_scheduled, ^live, _delay}

    # Backfilled first, then delivered after all.
    {:ok, %Thread{}} =
      Triage.handle_slack_event(workspace, slack_message_event(channel, %{"text" => "Late", "ts" => missed}))

    assert [] = Triage.backfill_slack_workspace(workspace)
    assert [%Message{text: "Live"}, %Message{text: "Late"}] = Repo.all(from m in Message, order_by: m.posted_at)
  end

  test "reads back no further than the channel's connection, nor than a week", %{workspace: workspace, channel: channel} do
    test = self()

    Req.Test.stub(Rail.Slack, fn conn ->
      case conn.request_path do
        "/api/users.info" ->
          Req.Test.json(conn, %{"ok" => true, "user" => %{"real_name" => "Priya"}})

        "/api/conversations.history" ->
          send(test, {:history, conn.query_params["oldest"]})
          Req.Test.json(conn, %{"ok" => true, "messages" => []})
      end
    end)

    connected = "#{DateTime.to_unix(channel.inserted_at)}.000000"
    assert [] = Triage.backfill_slack_workspace(workspace)
    assert_received {:history, ^connected}

    # A channel connected long ago, whose newest thread is older than the week too.
    Repo.update_all(from(c in SlackChannel, where: c.id == ^channel.id),
      set: [inserted_at: DateTime.shift(DateTime.utc_now(), day: -30)]
    )

    week_ago = System.os_time(:second) - 7 * 86_400

    {:ok, %Thread{}} =
      Triage.handle_slack_event(workspace, slack_message_event(channel, %{"ts" => "#{week_ago - 86_400}.000100"}))

    assert [] = Triage.backfill_slack_workspace(workspace)
    assert_received {:history, oldest}
    assert_in_delta String.to_float(oldest), week_ago, 5
  end

  test "a channel whose history Slack will not give is skipped", %{workspace: workspace} do
    Req.Test.stub(Rail.Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "not_in_channel"}))

    assert capture_log(fn -> assert [] = Triage.backfill_slack_workspace(workspace) end) =~
             "could not read the history of rail-feedback"
  end
end
