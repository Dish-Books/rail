defmodule Rail.Support.Actions.DraftSupportReplyTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Support
  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Workers.RunSupportAgent

  setup %{project: project} do
    app_id = "app_#{System.unique_integer([:positive])}"

    Req.Test.stub(Rail.Intercom, fn
      %{request_path: "/me"} = conn ->
        Req.Test.json(conn, %{"app" => %{"id_code" => app_id}})

      %{request_path: "/conversations/77"} = conn ->
        Req.Test.json(conn, %{
          "id" => "77",
          "updated_at" => 1_790_000_100,
          "created_at" => 1_790_000_000,
          "state" => "open",
          "source" => %{"id" => "s77", "author" => %{"type" => "user", "name" => "Hannah"}, "body" => "<p>Wastage?</p>"}
        })
    end)

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Acme Support",
        "access_token" => "tok",
        "client_id" => "cid",
        "client_secret" => "secret"
      })

    {:ok, conversation} = Support.sync_intercom_conversation(workspace, "77")
    Phoenix.PubSub.subscribe(Rail.PubSub, "support")
    %{conversation: conversation}
  end

  test "asks the agent for a draft on a conversation no agent has read", %{
    conversation: %{id: conversation_id} = conversation
  } do
    assert {:ok, %Conversation{id: ^conversation_id, drafting_since: %DateTime{}, agent_error: nil}} =
             Support.draft_support_reply(system_scope(), conversation)

    assert_enqueued(worker: RunSupportAgent, args: %{"conversation_id" => conversation_id})
    assert_receive {:support_changed, ^conversation_id}
  end

  test "Try again clears the last pass's error, and a second ask keeps the first one's time", %{
    conversation: %{id: conversation_id} = conversation
  } do
    Repo.update_all(from(c in Conversation, where: c.id == ^conversation_id), set: [agent_error: "It failed."])

    {:ok, %Conversation{drafting_since: %DateTime{} = since}} = Support.draft_support_reply(system_scope(), conversation)

    assert {:ok, %Conversation{drafting_since: ^since, agent_error: nil}} =
             Support.draft_support_reply(system_scope(), conversation)

    assert [_one] = all_enqueued(worker: RunSupportAgent, args: %{"conversation_id" => conversation_id})
  end

  test "a person without the conversation's project gets nothing", %{conversation: conversation} do
    assert {:error, :not_found} = Support.draft_support_reply(user_scope(project_ids: []), conversation)
    refute_enqueued(worker: RunSupportAgent)
  end
end
