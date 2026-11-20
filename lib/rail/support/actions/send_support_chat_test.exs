defmodule Rail.Support.Actions.SendSupportChatTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Scope
  alias Rail.Support
  alias Rail.Support.Schemas.ChatMessage
  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Workers.RunSupportAgent
  alias Rail.Users

  setup %{project: project} do
    app_id = "app_#{System.unique_integer([:positive])}"

    Req.Test.stub(Rail.Intercom, fn
      %{request_path: "/me"} = conn ->
        Req.Test.json(conn, %{"app" => %{"id_code" => app_id}})

      %{request_path: "/conversations/88"} = conn ->
        Req.Test.json(conn, %{
          "id" => "88",
          "updated_at" => 1_790_000_100,
          "created_at" => 1_790_000_000,
          "state" => "open",
          "source" => %{"id" => "s88", "author" => %{"type" => "user", "name" => "James"}, "body" => "<p>Prices?</p>"}
        })
    end)

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Acme Support",
        "access_token" => "tok",
        "client_id" => "cid",
        "client_secret" => "secret"
      })

    {:ok, conversation} = Support.sync_intercom_conversation(workspace, "88")
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "chat_#{unique}",
        login: "chat_#{unique}",
        name: "Dana Whitfield",
        email: "chat_#{unique}@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    %{conversation: conversation, user: user}
  end

  test "records the person's message and asks the agent to act on it", %{
    conversation: %{id: conversation_id} = conversation,
    user: %{id: user_id} = user
  } do
    assert {:ok, %ChatMessage{author: :person, text: "Drop the workaround.", user_id: ^user_id}} =
             Support.send_support_chat(Scope.for_user(user), conversation, %{"text" => "  Drop the workaround.  "})

    assert %Conversation{drafting_since: %DateTime{}} = Repo.get!(Conversation, conversation_id)
    assert_enqueued(worker: RunSupportAgent, args: %{"conversation_id" => conversation_id})
  end

  test "a blank message is refused and asks for nothing", %{conversation: conversation, user: user} do
    assert {:error, %Ecto.Changeset{} = changeset} =
             Support.send_support_chat(Scope.for_user(user), conversation, %{"text" => "   "})

    assert %{text: ["can't be blank"]} = errors_on(changeset)
    refute_enqueued(worker: RunSupportAgent)
  end

  test "a person without the conversation's project is refused", %{conversation: conversation, user: user} do
    {:ok, outsider} = Users.update_user(system_scope(), user, %{project_ids: []})

    assert {:error, :not_found} =
             Support.send_support_chat(Scope.for_user(outsider), conversation, %{"text" => "Hello"})

    assert Repo.all(ChatMessage) == []
  end
end
