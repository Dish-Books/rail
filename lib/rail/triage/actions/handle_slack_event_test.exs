defmodule Rail.Triage.Actions.HandleSlackEventTest do
  use Rail.DataCase, async: true

  alias Rail.Triage
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread

  setup %{project: project} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "triage")
    connect_slack_channel(project, users: %{"U_PRIYA" => "Priya Natarajan", "U_DAN" => "Dan Okafor"})
  end

  test "a top-level message in a connected channel opens a Triaging thread and schedules a pass", %{
    workspace: workspace,
    channel: channel,
    project: %{id: project_id}
  } do
    assert {:ok, %Thread{id: thread_id, status: :triaging, project_id: ^project_id, external_id: "1790000000.000100"}} =
             Triage.handle_slack_event(
               workspace,
               slack_message_event(channel, %{
                 "text" => "Approved <@U_DAN> and <@U_X|Sam> say it is stuck <https://x.example|here>, &lt;sigh&gt;"
               })
             )

    assert_receive {:triage_scheduled, ^thread_id, 15_000}
    assert_receive {:triage_changed, ^thread_id}

    assert [
             %Message{
               author_name: "Priya Natarajan",
               from_bot: false,
               text: "Approved @Dan Okafor and @Sam say it is stuck here, <sigh>"
             }
           ] =
             Repo.all(from m in Message, where: m.thread_id == ^thread_id)
  end

  test "a screenshot posted with text is stored with the message and schedules a pass", %{
    workspace: workspace,
    channel: channel
  } do
    assert {:ok, %Thread{id: thread_id}} =
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
                   }
                 ]
               })
             )

    assert_receive {:triage_scheduled, ^thread_id, 15_000}

    assert [
             %Message{
               text: "this button is broken",
               images: [
                 %Message.Image{
                   external_id: "F_SHOT",
                   name: "button.png",
                   mimetype: "image/png",
                   url: "https://files.slack.com/files-pri/T1-F_SHOT/button.png"
                 }
               ]
             }
           ] = Repo.all(from m in Message, where: m.thread_id == ^thread_id)
  end

  test "of the files posted with a message only the images are kept, and a withheld file is kept unread", %{
    workspace: workspace,
    channel: channel
  } do
    assert {:ok, %Thread{id: thread_id}} =
             Triage.handle_slack_event(
               workspace,
               slack_message_event(channel, %{
                 "subtype" => "file_share",
                 "text" => "",
                 "files" => [
                   %{
                     "id" => "F_SHOT",
                     "name" => "button.png",
                     "mimetype" => "image/png",
                     "url_private" => "https://files.slack.com/files-pri/T1-F_SHOT/button.png"
                   },
                   %{
                     "id" => "F_PDF",
                     "name" => "spec.pdf",
                     "mimetype" => "application/pdf",
                     "url_private" => "https://files.slack.com/files-pri/T1-F_PDF/spec.pdf"
                   },
                   %{"id" => "F_HIDDEN", "file_access" => "check_file_info"},
                   "not a file"
                 ]
               })
             )

    assert [
             %Message{
               text: "",
               images: [
                 %Message.Image{external_id: "F_SHOT"},
                 %Message.Image{external_id: "F_HIDDEN", name: nil, mimetype: nil, url: nil}
               ]
             }
           ] = Repo.all(from m in Message, where: m.thread_id == ^thread_id)
  end

  test "a reply joins its thread", %{workspace: workspace, channel: channel} do
    {:ok, %Thread{id: thread_id}} = Triage.handle_slack_event(workspace, slack_message_event(channel, %{}))

    assert {:ok, %Thread{id: ^thread_id}} =
             Triage.handle_slack_event(
               workspace,
               slack_message_event(channel, %{
                 "ts" => "1790000100.000200",
                 "thread_ts" => "1790000000.000100",
                 "user" => "U_DAN",
                 "text" => "Same on BILL-91"
               })
             )

    assert 2 = Repo.aggregate(from(m in Message, where: m.thread_id == ^thread_id), :count)
  end

  test "a redelivered envelope stores one message", %{workspace: workspace, channel: channel} do
    event = slack_message_event(channel, %{})
    {:ok, %Thread{id: thread_id}} = Triage.handle_slack_event(workspace, event)
    {:ok, %Thread{id: ^thread_id}} = Triage.handle_slack_event(workspace, event)

    assert 1 = Repo.aggregate(from(m in Message, where: m.thread_id == ^thread_id), :count)
  end

  test "ignores what is not a person's new message in a connected channel", %{workspace: workspace, channel: channel} do
    for fields <- [
          %{"channel_type" => "im"},
          %{"channel_type" => "mpim"},
          %{"channel" => "C_NOT_CONNECTED"},
          %{"channel" => nil},
          %{"subtype" => "message_changed"},
          %{"type" => "reaction_added"}
        ] do
      assert :ignored = Triage.handle_slack_event(workspace, slack_message_event(channel, fields))
    end

    assert :ignored = Triage.handle_slack_event(workspace, %{"type" => "app_rate_limited"})
    assert [] = Repo.all(from t in Thread, where: t.slack_channel_id == ^channel.id)
  end

  test "a channel of another workspace is ignored", %{workspace: workspace, channel: channel} do
    assert :ignored = Triage.handle_slack_event(%{workspace | id: "sw_other"}, slack_message_event(channel, %{}))
  end

  describe "a bot's post" do
    setup %{workspace: workspace, channel: channel} do
      event =
        slack_message_event(channel, %{
          "subtype" => "bot_message",
          "user" => nil,
          "bot_id" => "B_POSTHOG",
          "username" => "PostHog",
          "text" => "",
          "attachments" => [%{"title" => "TypeError in checkout", "text" => "Cannot read properties of undefined"}],
          "blocks" => [
            %{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => "12 users affected"}},
            %{"type" => "divider"}
          ]
        })

      %{event: event, workspace: workspace, channel: channel}
    end

    test "is stored under its bot name, with its attachment text, and triaged in an opted-in channel", %{
      event: event,
      project: project
    } do
      %{workspace: workspace, channel: channel} = connect_slack_channel(project, bot_triage_enabled: true)
      event = put_in(event, ["event", "channel"], channel.external_id)

      assert {:ok, %Thread{id: thread_id}} = Triage.handle_slack_event(workspace, event)

      assert [
               %Message{
                 author_name: "PostHog",
                 author_external_id: "B_POSTHOG",
                 from_bot: true,
                 text: "TypeError in checkout\nCannot read properties of undefined\n12 users affected"
               }
             ] = Repo.all(from m in Message, where: m.thread_id == ^thread_id)

      assert_receive {:triage_scheduled, ^thread_id, 15_000}
    end

    test "is stored and triggers nothing in a channel without the option", %{event: event, workspace: workspace} do
      assert {:ok, %Thread{id: thread_id, status: :done}} = Triage.handle_slack_event(workspace, event)

      assert [%Message{from_bot: true}] = Repo.all(from m in Message, where: m.thread_id == ^thread_id)
      refute_received {:triage_scheduled, ^thread_id, _delay}
    end

    test "an external channel triages exactly what it would otherwise, bots only where the option is on", %{
      event: event,
      project: project
    } do
      %{workspace: workspace, channel: channel} = connect_slack_channel(project, external: true)

      assert {:ok, %Thread{id: person_id}} = Triage.handle_slack_event(workspace, slack_message_event(channel, %{}))
      assert_receive {:triage_scheduled, ^person_id, 15_000}

      bot = event |> put_in(["event", "channel"], channel.external_id) |> put_in(["event", "ts"], "1790000000.000200")
      assert {:ok, %Thread{id: bot_id, status: :done}} = Triage.handle_slack_event(workspace, bot)
      refute_received {:triage_scheduled, ^bot_id, _delay}

      %{workspace: workspace, channel: channel} = connect_slack_channel(project, external: true, bot_triage_enabled: true)

      assert {:ok, %Thread{id: bot_id}} =
               Triage.handle_slack_event(workspace, put_in(event, ["event", "channel"], channel.external_id))

      assert_receive {:triage_scheduled, ^bot_id, 15_000}
    end

    test "from Rail's own bot never triggers, even where bots do", %{event: event, project: project} do
      %{workspace: workspace, channel: channel} = connect_slack_channel(project, bot_triage_enabled: true)

      event =
        event
        |> put_in(["event", "channel"], channel.external_id)
        |> put_in(["event", "bot_id"], workspace.bot_id)
        |> put_in(["event", "bot_profile"], %{"name" => "Rail"})

      assert {:ok, %Thread{id: thread_id, status: :done}} = Triage.handle_slack_event(workspace, event)
      assert [%Message{author_name: "Rail"}] = Repo.all(from m in Message, where: m.thread_id == ^thread_id)
      refute_received {:triage_scheduled, ^thread_id, _delay}
    end
  end

  test "a person's message on a dismissed thread reopens it for review", %{workspace: workspace, channel: channel} do
    {:ok, thread} = Triage.handle_slack_event(workspace, slack_message_event(channel, %{}))
    dismisser = Rail.Scope.for_user(slack_user(workspace.external_id))

    {:ok, %Thread{status: :done, dismissed_at: %DateTime{}, dismissed_by_id: "usr_" <> _id}} =
      Triage.dismiss_triage_thread(dismisser, thread)

    reply =
      slack_message_event(channel, %{
        "ts" => "1790000500.000100",
        "thread_ts" => thread.external_id,
        "user" => "U_DAN",
        "text" => "It happened again today."
      })

    assert {:ok, %Thread{id: thread_id, status: :triaging, dismissed_at: nil, dismissed_by_id: nil}} =
             Triage.handle_slack_event(workspace, reply)

    assert_receive {:triage_scheduled, ^thread_id, 15_000}
  end
end
