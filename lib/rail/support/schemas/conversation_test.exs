defmodule Rail.Support.Schemas.ConversationTest do
  use Rail.DataCase, async: true

  alias Rail.Projects.Schemas.Project
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
end
