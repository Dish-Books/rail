defmodule Rail.Support.Actions.MarkSupportDoneTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Support
  alias Rail.Support.Schemas.Conversation
  alias Rail.Users

  setup %{project: project} do
    app_id = "app_#{System.unique_integer([:positive])}"

    Req.Test.stub(Rail.Intercom, fn
      %{request_path: "/me"} = conn ->
        Req.Test.json(conn, %{"app" => %{"id_code" => app_id}})

      %{request_path: "/conversations/55"} = conn ->
        Req.Test.json(conn, %{
          "id" => "55",
          "updated_at" => 1_790_000_100,
          "created_at" => 1_790_000_000,
          "state" => "open",
          "source" => %{"id" => "s55", "author" => %{"type" => "user", "name" => "Owen"}, "body" => "<p>Copy a menu?</p>"}
        })
    end)

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Acme Support",
        "access_token" => "tok",
        "client_id" => "cid",
        "client_secret" => "secret"
      })

    {:ok, conversation} = Support.sync_intercom_conversation(workspace, "55")
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "done_#{unique}",
        login: "done_#{unique}",
        email: "done_#{unique}@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    Phoenix.PubSub.subscribe(Rail.PubSub, "support")
    %{conversation: conversation, user: user}
  end

  test "moves the conversation to Done, saying who and when, and announces it", %{
    conversation: %{id: conversation_id} = conversation,
    user: %{id: user_id} = user
  } do
    assert {:ok, %Conversation{id: ^conversation_id, status: :done, done_by_id: ^user_id, done_at: %DateTime{}}} =
             Support.mark_support_done(Scope.for_user(user), conversation)

    assert %Conversation{status: :done, done_by_id: ^user_id} = Repo.get!(Conversation, conversation_id)
    assert_receive {:support_changed, ^conversation_id}
  end

  test "marking a done conversation again changes nothing", %{
    conversation: %{id: conversation_id} = conversation,
    user: %{id: user_id} = user
  } do
    {:ok, %Conversation{done_at: done_at}} = Support.mark_support_done(Scope.for_user(user), conversation)
    assert_receive {:support_changed, ^conversation_id}

    assert {:ok, %Conversation{status: :done, done_by_id: ^user_id, done_at: ^done_at}} =
             Support.mark_support_done(Scope.for_user(user), conversation)

    refute_receive {:support_changed, ^conversation_id}, 50
  end

  test "a person without the conversation's project is refused", %{
    conversation: %{id: conversation_id} = conversation,
    user: user
  } do
    {:ok, outsider} = Users.update_user(system_scope(), user, %{project_ids: []})

    assert {:error, :not_found} = Support.mark_support_done(Scope.for_user(outsider), conversation)
    assert %Conversation{status: :waiting} = Repo.get!(Conversation, conversation_id)
  end
end
