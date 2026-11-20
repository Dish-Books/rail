defmodule Rail.Triage.Schemas.ThreadTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Support.Schemas.Conversation
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
             Thread.outcome_label(%Thread{items: [%Item{issue_created_by: michael, reply_posted_by: jordan}]})

    assert "Replied by jordan" = Thread.outcome_label(%Thread{items: [%Item{reply_posted_by: jordan}]})
    assert "Needed no response" = Thread.outcome_label(%Thread{items: []})
    assert "Dismissed by Michael" = Thread.outcome_label(%Thread{dismissed_by: michael, items: []})
  end

  test "counts its items by kind and what is left to accept" do
    thread = %Thread{
      items: [
        %Item{kind: :bug, issue_title: "Bug", reply_text: "Thanks"},
        %Item{kind: :bug, issue_title: "Tracked", existing_issue_id: "iss_1", created_issue: %Issue{}},
        %Item{kind: :feature_request, reply_text: "Good call"}
      ]
    }

    assert %{bug: 2, feature_request: 1} = Thread.kind_counts(thread)
    assert 3 = Thread.to_accept_count(thread)
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
