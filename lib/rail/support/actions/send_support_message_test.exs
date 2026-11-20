defmodule Rail.Support.Actions.SendSupportMessageTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Scope
  alias Rail.Support
  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Workers.SyncIntercomConversation
  alias Rail.Users

  setup do
    Req.Test.verify_on_exit!()
    %{project: project} = triage_project(tracker: :local)
    unique = System.unique_integer([:positive])
    app_id = "app#{unique}"
    external_id = "#{unique}"

    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => app_id}}))

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Dishbooks Support",
        "access_token" => "tok",
        "client_id" => "cid",
        "client_secret" => "secret"
      })

    Req.Test.expect(Rail.Intercom, fn conn ->
      Req.Test.json(conn, %{
        "id" => external_id,
        "created_at" => 1_790_000_000,
        "updated_at" => 1_790_000_100,
        "state" => "open",
        "source" => %{
          "id" => "src1",
          "body" => "<p>The allergen sheet misses sesame.</p>",
          "author" => %{"type" => "user", "name" => "Marta Kowalczyk", "email" => "marta@example.com"}
        },
        "conversation_parts" => %{"conversation_parts" => []}
      })
    end)

    {:ok, conversation} = Support.sync_intercom_conversation(workspace, external_id)

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "ssm_#{unique}",
        login: "ssm_#{unique}",
        name: "Dana Whitfield",
        email: "ssm_#{unique}@example.com"
      })

    {:ok, user} =
      Users.update_user(system_scope(), user, %{
        project_ids: [project.id],
        intercom_admin_id: "adm_#{unique}",
        intercom_app_id: app_id,
        intercom_name: "Dana Whitfield",
        intercom_access_token: "dana-token"
      })

    Phoenix.PubSub.subscribe(Rail.PubSub, "support")

    %{
      conversation: conversation,
      workspace: workspace,
      user: user,
      scope: Scope.for_user(user),
      external_id: external_id
    }
  end

  test "posts the message as the person while the agent drafts, leaving the draft and status alone, and syncs it", %{
    conversation: %{id: conversation_id} = conversation,
    workspace: %{id: workspace_id},
    scope: scope,
    external_id: external_id
  } do
    {:ok, drafting} = Support.draft_support_reply(scope, conversation)

    Req.Test.expect(Rail.Intercom, fn conn ->
      assert conn.request_path == "/conversations/#{external_id}/reply"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer dana-token"]

      assert %{
               "message_type" => "comment",
               "type" => "admin",
               "admin_id" => "adm_" <> _unique,
               "body" => "<p>Hi Marta,<br>one more thing.</p><p>Sesame &lt;is&gt; next.</p>"
             } = conn |> Req.Test.raw_body() |> Jason.decode!()

      Req.Test.json(conn, %{"type" => "conversation"})
    end)

    assert {:ok, %Conversation{id: ^conversation_id}} =
             Support.send_support_message(scope, drafting, "  Hi Marta,\r\none more thing.\r\n\r\nSesame <is> next.\n")

    assert_receive {:support_changed, ^conversation_id}

    assert_enqueued(
      worker: SyncIntercomConversation,
      args: %{"workspace_id" => workspace_id, "external_id" => external_id, "draft" => false, "imported" => false}
    )

    assert %Conversation{status: :waiting, drafting_since: %DateTime{}, reply_text: nil, reply_posted_at: nil} =
             Repo.get!(Conversation, conversation_id)
  end

  test "a conversation marked done still takes a message, and stays done", %{conversation: conversation, scope: scope} do
    {:ok, done} = Support.mark_support_done(scope, conversation)
    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"type" => "conversation"}))

    assert {:ok, _conversation} = Support.send_support_message(scope, done, "Following up.")
    assert %Conversation{status: :done} = Repo.get!(Conversation, conversation.id)
  end

  test "Intercom refusing the message sends nothing and syncs nothing", %{conversation: conversation, scope: scope} do
    Req.Test.expect(Rail.Intercom, &Plug.Conn.send_resp(&1, 500, "down"))

    assert {:error, {:message_failed, {:intercom_error, 500, "down"}}} =
             Support.send_support_message(scope, conversation, "Hi Marta")

    refute_enqueued(worker: SyncIntercomConversation)
  end

  test "a blank message is refused without asking Intercom", %{conversation: conversation, scope: scope} do
    assert {:error, :no_message} = Support.send_support_message(scope, conversation, " \r\n ")
    assert {:error, :no_message} = Support.send_support_message(scope, conversation, nil)
  end

  test "a person with no Intercom link is refused, including one who unlinked after the page loaded", %{
    conversation: conversation,
    scope: scope
  } do
    {:ok, _unlinked} = Users.unlink_intercom(scope)

    assert {:error, :intercom_not_linked} = Support.send_support_message(scope, conversation, "Hi Marta")
  end

  test "a person linked to another Intercom app is refused", %{conversation: conversation, user: user} do
    {:ok, user} = Users.update_user(system_scope(), user, %{intercom_app_id: "another_app"})

    assert {:error, :intercom_other_workspace} =
             Support.send_support_message(Scope.for_user(user), conversation, "Hi Marta")
  end

  test "a conversation in a project the person cannot see is not found", %{conversation: conversation, user: user} do
    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: []})

    assert {:error, :not_found} = Support.send_support_message(Scope.for_user(user), conversation, "Hi Marta")
  end
end
