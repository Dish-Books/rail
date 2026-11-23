defmodule Rail.Support.Actions.SendSupportReplyTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Scope
  alias Rail.Support
  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Schemas.Item
  alias Rail.Tools
  alias Rail.Triage
  alias Rail.Triage.Schemas.Item, as: TriageItem
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users

  setup do
    Req.Test.verify_on_exit!()
    stub(Git, :checkout_detached_worktree, fn _project, worktree_path -> {:ok, worktree_path} end)
    stub(Git, :remove_worktree, fn _clone_path, _worktree_path -> :ok end)

    %{project: project} = triage_project(tracker: :local)
    {:ok, tracked} = Issues.create_issue(system_scope(), project, %{title: "A recipe scales from an event's covers"})
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
        "conversation_parts" => %{
          "conversation_parts" => [
            %{
              "id" => "p1",
              "part_type" => "note",
              "created_at" => 1_790_000_050,
              "body" => "<p>Looks like a bug.</p>",
              "author" => %{"type" => "admin", "name" => "Dana Whitfield"}
            }
          ]
        }
      })
    end)

    {:ok, conversation} = Support.sync_intercom_conversation(workspace, external_id)

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "ssr_#{unique}",
        login: "ssr_#{unique}",
        name: "Dana Whitfield",
        email: "ssr_#{unique}@example.com"
      })

    {:ok, user} =
      Users.update_user(system_scope(), user, %{
        project_ids: [project.id],
        intercom_admin_id: "adm_#{unique}",
        intercom_app_id: app_id,
        intercom_name: "Dana Whitfield",
        intercom_access_token: "dana-token"
      })

    result = %{
      "title" => "The allergen sheet misses sesame",
      "message" => "Sesame is a real bug.",
      "reply" => "Hi Marta, thanks.\nWe looked.\n\nWe've passed <this> on to the dev team.",
      "items" => [
        %{
          "key" => "sesame",
          "kind" => "bug",
          "title" => "Sesame is missing",
          "verdict" => "confirmed",
          "summary" => "Tahini sits under Seeds.",
          "evidence" => [%{"file" => "lib/allergens.ex", "lines" => "42", "excerpt" => "tahini", "holds" => true}],
          "assumptions" => [%{"text" => "Every tahini contains sesame."}],
          "issue" => %{
            "title" => "The allergen sheet lists sesame for tahini",
            "description" => "Root cause.",
            "priority" => "urgent",
            "estimate" => 2
          }
        },
        %{
          "key" => "pdf",
          "kind" => "feature_request",
          "title" => "PDF export of the whole method",
          "verdict" => "partly_built",
          "issue" => %{"title" => "A recipe's PDF prints the whole method", "priority" => "high"}
        },
        %{
          "key" => "scaling",
          "kind" => "feature_request",
          "title" => "Scale from an event's covers",
          "verdict" => "not_built",
          "existing_issue" => tracked.identifier
        }
      ]
    }

    %{
      project: project,
      conversation: conversation,
      user: user,
      scope: Scope.for_user(user),
      result: result,
      external_id: external_id,
      app_id: app_id,
      tracked: tracked
    }
  end

  setup %{conversation: conversation, result: result} = context do
    result = Map.merge(result, Map.get(context, :result_overrides, %{}))

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      conversation |> Conversation.scratch_path() |> Path.join("result.json") |> File.write!(Jason.encode!(result))
      {:ok, ""}
    end)

    {:ok, _drafting} = Support.draft_support_reply(system_scope(), conversation)
    :ok = Support.run_support_agent(conversation)
    Phoenix.PubSub.subscribe(Rail.PubSub, "support")
    Phoenix.PubSub.subscribe(Rail.PubSub, "triage")
    :ok
  end

  test "posts the reply as the person and forwards every listed item not already tracked into one triage thread", %{
    conversation: %{id: conversation_id} = conversation,
    scope: scope,
    user: %{id: user_id},
    external_id: external_id,
    project: %{id: project_id},
    app_id: app_id
  } do
    Req.Test.expect(Rail.Intercom, fn conn ->
      assert conn.request_path == "/conversations/#{external_id}/reply"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer dana-token"]

      assert %{
               "message_type" => "comment",
               "type" => "admin",
               "admin_id" => "adm_" <> _unique,
               "body" => "<p>Hi Marta, thanks.<br>We looked.</p><p>We&#39;ve passed &lt;this&gt; on to the dev team.</p>"
             } = conn |> Req.Test.raw_body() |> Jason.decode!()

      Req.Test.json(conn, %{"type" => "conversation"})
    end)

    assert {:ok, %Conversation{reply_posted_at: %DateTime{}, reply_posted_by_id: ^user_id, send_error: nil}} =
             Support.send_support_reply(scope, conversation)

    inbox_url = "https://app.intercom.com/a/inbox/#{app_id}/inbox/conversation/#{external_id}"
    assert_receive {:support_changed, ^conversation_id}
    # "triage" is one topic for every test, so only this conversation's thread counts.
    [%Thread{id: thread_id}] = Repo.all(from t in Thread, where: t.support_conversation_id == ^conversation_id)
    assert_receive {:triage_changed, ^thread_id}

    assert %Thread{
             project_id: ^project_id,
             support_conversation_id: ^conversation_id,
             forwarded_by_id: ^user_id,
             status: :waiting,
             slack_channel_id: nil,
             title: "The allergen sheet misses sesame",
             permalink: ^inbox_url,
             items: [
               %TriageItem{
                 key: "sesame",
                 position: 1,
                 kind: :bug,
                 verdict: :confirmed,
                 issue_title: "The allergen sheet lists sesame for tahini",
                 issue_priority: :urgent,
                 issue_estimate: 2,
                 evidence: [%TriageItem.Evidence{file: "lib/allergens.ex", holds: true}],
                 assumptions: [%TriageItem.Assumption{text: "Every tahini contains sesame.", corrected: false}]
               },
               %TriageItem{key: "pdf", position: 2, kind: :feature_request, verdict: :partly_built}
             ]
           } = Thread |> Repo.get!(thread_id) |> Repo.preload(items: from(i in TriageItem, order_by: i.position))

    assert [
             %Item{key: "pdf", forwarded_at: %DateTime{}},
             %Item{key: "scaling", forwarded_at: nil, existing_issue_id: "iss_" <> _tracked},
             %Item{key: "sesame", forwarded_at: %DateTime{}}
           ] = Repo.all(from i in Item, where: i.conversation_id == ^conversation_id, order_by: i.key)

    # A second click finds the reply posted and nothing left to forward.
    assert {:ok, %Conversation{reply_posted_by_id: ^user_id}} = Support.send_support_reply(scope, conversation)
    assert 1 = Repo.aggregate(from(t in Thread, where: t.support_conversation_id == ^conversation_id), :count)
    refute_receive {:triage_changed, ^thread_id}
  end

  test "a Send that finds another one holding the lock posts nothing", %{
    conversation: %{id: conversation_id} = conversation,
    scope: scope
  } do
    Repo.update_all(from(c in Conversation, where: c.id == ^conversation_id), set: [send_started_at: DateTime.utc_now()])

    assert {:error, :already_sent} = Support.send_support_reply(scope, conversation)
    assert %Conversation{reply_posted_at: nil} = Repo.get!(Conversation, conversation_id)
    refute Repo.exists?(from(t in Thread, where: t.support_conversation_id == ^conversation_id))
  end

  test "a lock left by a Send that died long ago is taken over", %{
    conversation: %{id: conversation_id} = conversation,
    scope: scope
  } do
    stale = DateTime.shift(DateTime.utc_now(), minute: -3)
    Repo.update_all(from(c in Conversation, where: c.id == ^conversation_id), set: [send_started_at: stale])
    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"type" => "conversation"}))

    assert {:ok, %Conversation{reply_posted_at: %DateTime{}, send_started_at: nil}} =
             Support.send_support_reply(scope, conversation)
  end

  test "a forward that fails after the reply posted keeps the reply, and the retry forwards without posting again", %{
    conversation: %{id: conversation_id} = conversation,
    scope: scope,
    user: user
  } do
    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"type" => "conversation"}))
    expect(Triage, :create_forwarded_thread, fn _scope, _conversation, _items -> {:error, :boom} end)

    assert {:error, {:forward_failed, :boom}} = Support.send_support_reply(scope, conversation)

    assert %Conversation{
             reply_posted_at: %DateTime{},
             send_error: "Posted the reply in Intercom, but could not forward to triage."
           } = Repo.get!(Conversation, conversation_id)

    assert [] = Repo.all(from i in Item, where: i.conversation_id == ^conversation_id and not is_nil(i.forwarded_at))
    refute Repo.exists?(from(t in Thread, where: t.support_conversation_id == ^conversation_id))

    # Retrying only the forward needs no link, and Intercom is not called again.
    {:ok, _unlinked} = Users.unlink_intercom(scope)
    stub(Triage, :create_forwarded_thread, &Mimic.call_original(Triage, :create_forwarded_thread, [&1, &2, &3]))

    assert {:ok, %Conversation{send_error: nil}} = Support.send_support_reply(Scope.for_user(user), conversation)
    assert 1 = Repo.aggregate(from(t in Thread, where: t.support_conversation_id == ^conversation_id), :count)
  end

  test "a forward that raises keeps the reply posted, records why and still raises", %{
    conversation: %{id: conversation_id} = conversation,
    scope: scope
  } do
    # One expect, verified on exit, so the reply is posted exactly once.
    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"type" => "conversation"}))
    expect(Triage, :create_forwarded_thread, fn _scope, _conversation, _items -> raise "triage is down" end)

    assert_raise RuntimeError, "triage is down", fn -> Support.send_support_reply(scope, conversation) end
    assert_received {:support_changed, ^conversation_id}

    assert %Conversation{
             reply_posted_at: %DateTime{},
             send_error: "Posted the reply in Intercom, but could not forward to triage."
           } = Repo.get!(Conversation, conversation_id)

    refute Repo.exists?(from(t in Thread, where: t.support_conversation_id == ^conversation_id))
  end

  test "Intercom refusing the reply sends and forwards nothing, and frees the Send to try again", %{
    conversation: %{id: conversation_id} = conversation,
    scope: scope
  } do
    Req.Test.expect(Rail.Intercom, &(&1 |> Plug.Conn.put_status(422) |> Req.Test.json(%{"errors" => []})))

    assert {:error, {:reply_failed, {:intercom_error, 422, _body}}} = Support.send_support_reply(scope, conversation)

    assert %Conversation{reply_posted_at: nil, send_started_at: nil} = Repo.get!(Conversation, conversation_id)
    refute Repo.exists?(from(t in Thread, where: t.support_conversation_id == ^conversation_id))

    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"type" => "conversation"}))
    assert {:ok, %Conversation{reply_posted_at: %DateTime{}}} = Support.send_support_reply(scope, conversation)
  end

  test "a person with no Intercom link is refused, including one who unlinked after the page loaded", %{
    conversation: conversation,
    scope: scope
  } do
    {:ok, _unlinked} = Users.unlink_intercom(scope)

    assert {:error, :intercom_not_linked} = Support.send_support_reply(scope, conversation)
  end

  test "a person linked to another Intercom app is refused", %{conversation: conversation, user: user} do
    {:ok, user} = Users.update_user(system_scope(), user, %{intercom_app_id: "another_app"})

    assert {:error, :intercom_other_workspace} = Support.send_support_reply(Scope.for_user(user), conversation)
  end

  test "Send waits while the agent drafts", %{conversation: conversation, scope: scope} do
    {:ok, drafting} = Support.draft_support_reply(scope, conversation)

    assert {:error, :drafting} = Support.send_support_reply(scope, drafting)
  end

  test "a conversation in a project the person cannot see is not found", %{conversation: conversation, user: user} do
    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: []})

    assert {:error, :not_found} = Support.send_support_reply(Scope.for_user(user), conversation)
  end

  @tag result_overrides: %{"reply" => nil}
  test "with no reply there is nothing to send", %{conversation: conversation, scope: scope} do
    assert {:error, :no_reply} = Support.send_support_reply(scope, conversation)
  end

  @tag result_overrides: %{"items" => []}
  test "a reply with nothing to forward posts and makes no thread", %{
    conversation: %{id: conversation_id} = conversation,
    scope: scope
  } do
    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"type" => "conversation"}))

    assert {:ok, %Conversation{reply_posted_at: %DateTime{}}} = Support.send_support_reply(scope, conversation)
    assert_receive {:support_changed, ^conversation_id}
    # "triage" is one topic for every test, so the thread's absence is what shows nothing was forwarded.
    refute Repo.exists?(from(t in Thread, where: t.support_conversation_id == ^conversation_id))
  end
end
