defmodule Rail.Support.Actions.UpdateSupportDraftTest do
  use Rail.DataCase, async: true

  alias Rail.Support
  alias Rail.Support.Schemas.Conversation

  setup %{project: project} do
    app_id = "app_#{System.unique_integer([:positive])}"

    Req.Test.stub(Rail.Intercom, fn
      %{request_path: "/me"} = conn ->
        Req.Test.json(conn, %{"app" => %{"id_code" => app_id}})

      %{request_path: "/conversations/99"} = conn ->
        Req.Test.json(conn, %{
          "id" => "99",
          "updated_at" => 1_790_000_100,
          "created_at" => 1_790_000_000,
          "state" => "open",
          "source" => %{"id" => "s99", "author" => %{"type" => "user", "name" => "Ben"}, "body" => "<p>Dates?</p>"}
        })
    end)

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Acme Support",
        "access_token" => "tok",
        "client_id" => "cid",
        "client_secret" => "secret"
      })

    {:ok, conversation} = Support.sync_intercom_conversation(workspace, "99")
    Phoenix.PubSub.subscribe(Rail.PubSub, "support")
    %{conversation: conversation}
  end

  test "saves the reply as the person types it, and announces it", %{
    conversation: %{id: conversation_id} = conversation
  } do
    assert {:ok, %Conversation{id: ^conversation_id, reply_text: "Hi Ben"}} =
             Support.update_support_draft(system_scope(), conversation, %{"reply_text" => "Hi Ben"})

    assert %Conversation{reply_text: "Hi Ben"} = Repo.get!(Conversation, conversation_id)
    assert_receive {:support_changed, ^conversation_id}
  end

  test "is refused while the agent works on the draft", %{conversation: %{id: conversation_id} = conversation} do
    {:ok, _conversation} = Support.draft_support_reply(system_scope(), conversation)

    assert {:error, :drafting} =
             Support.update_support_draft(system_scope(), conversation, %{"reply_text" => "Typed meanwhile"})

    assert %Conversation{reply_text: nil} = Repo.get!(Conversation, conversation_id)
  end

  test "is refused once the reply is posted", %{conversation: %{id: conversation_id} = conversation} do
    Repo.update_all(from(c in Conversation, where: c.id == ^conversation_id), set: [reply_posted_at: DateTime.utc_now()])

    assert {:error, :already_sent} =
             Support.update_support_draft(system_scope(), conversation, %{"reply_text" => "Too late"})
  end

  test "a person without the conversation's project is refused", %{conversation: conversation} do
    assert {:error, :not_found} =
             Support.update_support_draft(user_scope(project_ids: []), conversation, %{"reply_text" => "Hi"})
  end
end
