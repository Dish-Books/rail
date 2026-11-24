defmodule Rail.Support.Schemas.ConversationTest do
  use Rail.DataCase, async: true

  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Projects.Schemas.Project
  alias Rail.Support.Schemas.ChatMessage
  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Schemas.Item
  alias Rail.Support.Schemas.Message

  test "the import starts a closed conversation Done and anything else Waiting" do
    assert :done = Conversation.calculate_first_status("closed")
    assert :waiting = Conversation.calculate_first_status("open")
    assert :waiting = Conversation.calculate_first_status("snoozed")
    assert [:waiting, :done] = Conversation.statuses()
  end

  test "only a customer message newer than Mark done reopens a Done conversation" do
    done = %Conversation{status: :done, done_at: ~U[2026-11-20 10:00:00Z]}

    assert Conversation.reopened?(done, ~U[2026-11-20 10:05:00Z])
    refute Conversation.reopened?(done, ~U[2026-11-20 09:55:00Z])
    refute Conversation.reopened?(done, nil)
    refute Conversation.reopened?(%Conversation{status: :waiting}, ~U[2026-11-20 10:05:00Z])
  end

  test "Mark done records who and when" do
    assert %Ecto.Changeset{changes: %{status: :done, done_by_id: "usr_1", done_at: %DateTime{}}} =
             Conversation.done_changeset(%Conversation{}, "usr_1")
  end

  test "the draft changeset takes only the reply" do
    assert %Ecto.Changeset{changes: %{reply_text: "Hi"} = changes} =
             Conversation.draft_changeset(%Conversation{}, %{"reply_text" => "Hi", "status" => "done"})

    refute Map.has_key?(changes, :status)
  end

  test "a reply's \\r\\n line breaks are stored as \\n, so the stored text sent back is no change" do
    conversation = %Conversation{reply_text: "Hi\n\nPassed on."}

    assert Conversation.draft_changeset(conversation, %{"reply_text" => "Hi\r\n\r\nPassed on."}).changes == %{}

    assert %Ecto.Changeset{changes: %{reply_text: nil}} =
             Conversation.draft_changeset(conversation, %{"reply_text" => ""})
  end

  test "Send's label counts the items it forwards, and only forwards once the reply is posted" do
    to_forward = %Item{issue_title: "Sesame shows on the sheet"}
    tracked = %Item{existing_issue_id: "iss_1", issue_title: "Tracked"}
    forwarded = %Item{issue_title: "Done", forwarded_at: ~U[2026-11-20 10:00:00Z]}
    untitled = %Item{issue_title: "  "}

    assert "Send reply & forward 1 to dev" =
             Conversation.send_label(%Conversation{items: [to_forward, tracked, forwarded, untitled]})

    assert "Send reply" = Conversation.send_label(%Conversation{items: [tracked]})

    assert "Forward 1 to dev" =
             Conversation.send_label(%Conversation{reply_posted_at: ~U[2026-11-20 10:00:00Z], items: [to_forward]})
  end

  test "drafting while a pass is asked for or running" do
    assert Conversation.drafting?(%Conversation{drafting_since: ~U[2026-11-20 10:00:00Z]})
    refute Conversation.drafting?(%Conversation{})
  end

  test "the title, else the first message, else who wrote in" do
    assert "Sesame" = Conversation.title_or_preview(%Conversation{title: "Sesame"})
    assert "Hello" = Conversation.title_or_preview(%Conversation{title: "", messages: [%Message{text: "Hello"}]})

    assert "Conversation with Marta" =
             Conversation.title_or_preview(%Conversation{customer_name: "Marta", messages: [%Message{text: ""}]})

    assert "Conversation with a customer" = Conversation.title_or_preview(%Conversation{})
  end

  test "a pass works in its own scratch folder and worktree" do
    conversation = %Conversation{id: "scv_1", project_id: "prj_1", project: %Project{clone_path: "/clones/x"}}

    assert String.ends_with?(Conversation.scratch_path(conversation), "/prj_1/support/scv_1")
    assert "/clones/x/.worktrees/support-scv_1" = Conversation.worktree_path(conversation)
  end

  test "the chat box gives way to nothing with no rule waiting, and to the oldest undecided one with the count" do
    assert {nil, 0} = Conversation.next_rule(%Conversation{learning_proposals: []})
    assert {nil, 0} = Conversation.next_rule(%Conversation{learning_proposals: [%LearningProposal{status: :approved}]})

    proposals = [
      %LearningProposal{id: "lpr_decided", status: :rejected},
      %LearningProposal{id: "lpr_oldest", status: :pending},
      %LearningProposal{id: "lpr_newer", status: :pending}
    ]

    assert {%LearningProposal{id: "lpr_oldest"}, 2} = Conversation.next_rule(%Conversation{learning_proposals: proposals})
  end

  test "a proposing line's note ends with who decided each rule, falling back to their login" do
    conversation = %Conversation{
      chat_messages: [
        %ChatMessage{id: "sct_1", author: :agent, changes: "Edited the reply · Proposed 2 rules"},
        %ChatMessage{id: "sct_2", author: :agent, changes: nil},
        %ChatMessage{id: "sct_3", author: :agent, changes: "Proposed a rule"},
        %ChatMessage{id: "sct_4", author: :agent, changes: "Proposed a rule"}
      ],
      learning_proposals: [
        %LearningProposal{support_chat_message_id: "sct_1", status: :approved, decided_by: %{name: "Dana Kim"}},
        %LearningProposal{support_chat_message_id: "sct_1", status: :rejected, decided_by: %{name: "", login: "dkim"}},
        %LearningProposal{support_chat_message_id: "sct_2", status: :approved, decided_by: nil},
        %LearningProposal{support_chat_message_id: "sct_3", status: :pending}
      ]
    }

    assert [
             %ChatMessage{changes: "Edited the reply · Proposed 2 rules · Approved by Dana Kim · Rejected by dkim"},
             %ChatMessage{changes: "Approved by someone"},
             %ChatMessage{changes: "Proposed a rule"},
             %ChatMessage{changes: "Proposed a rule"}
           ] = Conversation.calculate_chat_lines(conversation)
  end
end
