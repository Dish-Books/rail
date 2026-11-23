defmodule Rail.Triage.Schemas.ThreadTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Support.Schemas.Conversation
  alias Rail.Triage.Schemas.ChatMessage
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users.Schemas.User

  test "names a thread by its title, else its first words, else its author" do
    assert "Stuck" = Thread.title_or_preview(%Thread{title: "Stuck"})
    assert "sync at 11:30?" = Thread.title_or_preview(%Thread{messages: [%Message{text: " sync at 11:30? "}]})

    assert "Message from PostHog" =
             Thread.title_or_preview(%Thread{messages: [%Message{text: "", author_name: "PostHog"}]})

    assert "Slack thread" = Thread.title_or_preview(%Thread{messages: []})
  end

  test "says how a finished thread ended" do
    michael = %User{name: "Michael", login: "michael"}
    jordan = %User{name: nil, login: "jordan"}

    assert "Accepted by Michael" =
             Thread.outcome_label(%Thread{reply_posted_by: jordan, items: [%Item{issue_created_by: michael}]})

    assert "Replied by jordan" = Thread.outcome_label(%Thread{reply_posted_by: jordan, items: [%Item{}]})
    assert "Nothing sent" = Thread.outcome_label(%Thread{items: [%Item{ignored: true}]})
    assert "Needed no response" = Thread.outcome_label(%Thread{items: []})
    assert "Dismissed by Michael" = Thread.outcome_label(%Thread{dismissed_by: michael, items: []})
  end

  test "counts its items by kind, and what Send would do" do
    thread = %Thread{
      reply_text: "Thanks both",
      items: [
        %Item{kind: :bug, issue_title: "Bug"},
        %Item{kind: :bug, existing_issue_id: "iss_1", followup_text: "Seen again", created_issue: %Issue{}},
        %Item{kind: :feature_request, issue_title: "Ignored", ignored: true}
      ]
    }

    assert %{bug: 2, feature_request: 1} = Thread.kind_counts(thread)
    assert 3 = Thread.to_accept_count(thread)
    assert "Send reply, create 1 ticket & update 1" = Thread.send_label(thread)
    assert Thread.pending?(thread)
  end

  test "the button names only the parts there are" do
    bug = %Item{issue_title: "Bug"}

    assert "Send reply & create 2 tickets" = Thread.send_label(%Thread{reply_text: "Hi", items: [bug, bug]})
    assert "Create 2 tickets" = Thread.send_label(%Thread{items: [bug, bug]})
    assert "Send reply" = Thread.send_label(%Thread{reply_text: "Hi", items: []})
    assert "Update 1" = Thread.send_label(%Thread{items: [%Item{existing_issue_id: "iss_1", followup_text: "More"}]})
    assert nil == Thread.send_label(%Thread{reply_text: "  ", items: [%Item{issue_title: "Bug", ignored: true}]})
    refute Thread.pending?(%Thread{items: []})
  end

  test "a dismissed or posted thread has nothing to send" do
    now = DateTime.utc_now()
    items = [%Item{issue_title: "Bug"}, %Item{existing_issue_id: "iss_1", followup_text: "More"}]

    assert nil == Thread.send_label(%Thread{reply_text: "Hi", dismissed_at: now, items: items})
    assert [] = Thread.to_create(%Thread{dismissed_at: now, items: items})
    assert [] = Thread.to_update(%Thread{dismissed_at: now, items: items})
    refute Thread.reply_draft?(%Thread{reply_text: "Hi", reply_posted_at: now})
  end

  test "the reply is stored with the line breaks the agent writes, and an emptied one stays empty" do
    assert %{changes: %{reply_text: "Hi\n\nThanks"}} =
             Thread.reply_changeset(%Thread{}, %{"reply_text" => "Hi\r\n\r\nThanks"})

    assert %{changes: %{reply_text: ""}} = Thread.reply_changeset(%Thread{reply_text: "Hi"}, %{"reply_text" => ""})
  end

  test "a Send holds the thread for two minutes at most" do
    assert Thread.sending?(%Thread{send_started_at: DateTime.utc_now()})
    refute Thread.sending?(%Thread{send_started_at: DateTime.shift(DateTime.utc_now(), minute: -3)})
    refute Thread.sending?(%Thread{})
    assert 2 = Thread.send_stale_after_minutes()
  end

  test "the chat owes a pass for a person's line newer than the last pass's start" do
    read_at = ~U[2026-11-20 10:00:00.000000Z]
    before = %ChatMessage{author: :person, inserted_at: ~U[2026-11-20 09:59:00.000000Z]}
    since = %ChatMessage{author: :person, inserted_at: ~U[2026-11-20 10:00:01.000000Z]}
    answer = %ChatMessage{author: :agent, inserted_at: ~U[2026-11-20 10:01:00.000000Z]}

    refute Thread.chat_owed?(%Thread{chat_read_at: read_at, chat_messages: [before, answer]})
    assert Thread.chat_owed?(%Thread{chat_read_at: read_at, chat_messages: [before, since]})
    assert Thread.chat_owed?(%Thread{chat_read_at: nil, chat_messages: [before]})
    refute Thread.chat_owed?(%Thread{chat_read_at: nil, chat_messages: []})
  end

  test "a forwarded thread names Intercom as its source, has no channel and never triggers a pass" do
    conversation = %Conversation{id: "scv_1", project_id: "prj_1", external_id: "42", title: "Sesame"}
    changeset = Thread.forwarded_changeset(conversation, %User{id: "usr_1"}, "https://app.intercom.com/a/inbox/x")

    assert %Thread{
             project_id: "prj_1",
             support_conversation_id: "scv_1",
             forwarded_by_id: "usr_1",
             status: :waiting,
             slack_channel_id: nil,
             external_id: "intercom:42:" <> _microseconds,
             title: "Sesame",
             permalink: "https://app.intercom.com/a/inbox/x"
           } = forwarded = Ecto.Changeset.apply_changes(changeset)

    assert Thread.forwarded?(forwarded)
    assert "Intercom" = Thread.source_label(forwarded)
    assert "Intercom conversation" = Thread.link_label(forwarded)
    refute Thread.external?(forwarded)
    refute Thread.triggering?(forwarded, %Message{from_bot: false})
  end

  test "a Slack thread names its channel, and is external when its channel is" do
    slack = %Thread{slack_channel_id: "sc_1", slack_channel: %SlackChannel{name: "feedback", external: true}}

    refute Thread.forwarded?(slack)
    assert "#feedback" = Thread.source_label(slack)
    assert "Slack thread" = Thread.link_label(slack)
    assert Thread.external?(slack)
  end
end
