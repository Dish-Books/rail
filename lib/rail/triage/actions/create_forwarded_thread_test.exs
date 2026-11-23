defmodule Rail.Triage.Actions.CreateForwardedThreadTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Support
  alias Rail.Support.Schemas.Item, as: SupportItem
  alias Rail.Triage
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users

  setup do
    %{project: project} = triage_project()
    unique = System.unique_integer([:positive])
    app_id = "app#{unique}"

    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => app_id}}))

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Support",
        "access_token" => "tok",
        "client_id" => "cid",
        "client_secret" => "secret"
      })

    Req.Test.expect(Rail.Intercom, fn conn ->
      Req.Test.json(conn, %{
        "id" => "#{unique}",
        "created_at" => 1_790_000_000,
        "updated_at" => 1_790_000_100,
        "state" => "open",
        "source" => %{
          "id" => "src1",
          "subject" => "<p>Sesame</p>",
          "body" => "<p>The sheet misses sesame.</p>",
          "author" => %{"type" => "user", "name" => "Marta", "email" => "marta@example.com"},
          "attachments" => [%{"url" => "https://files.intercom.example/a.pdf", "name" => "recipe.pdf"}]
        },
        "conversation_parts" => %{
          "conversation_parts" => [
            %{
              "id" => "p1",
              "part_type" => "comment",
              "created_at" => 1_790_000_010,
              "body" => "<p>Did that help?</p>",
              "author" => %{"type" => "bot", "name" => "Fin"}
            },
            %{
              "id" => "p2",
              "part_type" => "note",
              "created_at" => 1_790_000_020,
              "body" => "<p>Looks like a bug.</p>",
              "author" => %{"type" => "admin", "name" => "Dana"}
            }
          ]
        }
      })
    end)

    {:ok, synced} = Support.sync_intercom_conversation(workspace, "#{unique}")
    {:ok, conversation} = Support.get_support_conversation(system_scope(), synced.id)

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "cft_#{unique}", login: "cft_#{unique}", email: "cft_#{unique}@example.com"})

    items = [
      %SupportItem{
        key: "sesame",
        kind: :bug,
        title: "Sesame is missing",
        verdict: :confirmed,
        summary: "Tahini sits under Seeds.",
        evidence: [%SupportItem.Evidence{file: "lib/allergens.ex", lines: "42", excerpt: "tahini", holds: true}],
        assumptions: [%SupportItem.Assumption{text: "Tahini has sesame.", corrected: false}],
        issue_title: "The allergen sheet lists sesame",
        issue_description: "Root cause.",
        issue_priority: :urgent,
        issue_estimate: 2
      },
      %SupportItem{
        key: "pdf",
        kind: :feature_request,
        title: "Whole method in the PDF",
        verdict: :partly_built,
        issue_title: "A recipe's PDF prints the whole method"
      }
    ]

    %{project: project, conversation: conversation, user: user, items: items, app_id: app_id, external_id: "#{unique}"}
  end

  test "makes a Waiting thread holding the conversation's messages and the items as drafted", %{
    project: %{id: project_id},
    conversation: %{id: conversation_id} = conversation,
    user: %{id: user_id} = user,
    items: items,
    app_id: app_id,
    external_id: external_id
  } do
    inbox_url = "https://app.intercom.com/a/inbox/#{app_id}/inbox/conversation/#{external_id}"

    assert {:ok, %Thread{id: thread_id} = thread} =
             Triage.create_forwarded_thread(Scope.for_user(user), conversation, items)

    assert %Thread{
             project_id: ^project_id,
             support_conversation_id: ^conversation_id,
             forwarded_by_id: ^user_id,
             slack_channel_id: nil,
             status: :waiting,
             title: "Sesame",
             permalink: ^inbox_url
           } = thread

    assert Thread.forwarded?(thread)
    assert "Intercom" = Thread.source_label(thread)
    assert "Intercom conversation" = Thread.link_label(thread)
    refute Thread.external?(thread)

    assert [
             %Message{author_name: "Marta", from_bot: false, text: "The sheet misses sesame.\nAttached: recipe.pdf"},
             %Message{author_name: "Fin", from_bot: true, text: "Did that help?"},
             %Message{author_name: "Dana", from_bot: false, text: "Internal note: Looks like a bug."} = note
           ] = Repo.all(from m in Message, where: m.thread_id == ^thread_id, order_by: m.posted_at)

    refute Thread.triggering?(thread, note)

    assert [
             %Item{
               key: "sesame",
               position: 1,
               kind: :bug,
               verdict: :confirmed,
               summary: "Tahini sits under Seeds.",
               evidence: [%Item.Evidence{file: "lib/allergens.ex", lines: "42", excerpt: "tahini", holds: true}],
               assumptions: [%Item.Assumption{text: "Tahini has sesame.", corrected: false}],
               issue_title: "The allergen sheet lists sesame",
               issue_priority: :urgent,
               issue_estimate: 2,
               reply_text: nil
             },
             %Item{key: "pdf", position: 2, kind: :feature_request, verdict: :partly_built}
           ] = Repo.all(from i in Item, where: i.thread_id == ^thread_id, order_by: i.position)
  end

  test "an item triage cannot take rolls the whole thread back", %{
    conversation: conversation,
    user: user,
    items: [%SupportItem{} = bug | _request]
  } do
    unfit = %{bug | verdict: :built}

    assert {:error, %Ecto.Changeset{} = changeset} =
             Triage.create_forwarded_thread(Scope.for_user(user), conversation, [unfit])

    assert %{verdict: [_unfit]} = errors_on(changeset)
    refute Repo.exists?(from(t in Thread, where: t.support_conversation_id == ^conversation.id))
  end

  test "loads with who forwarded it and the conversation in order", %{
    conversation: conversation,
    user: %{id: user_id} = user,
    items: items
  } do
    {:ok, %Thread{id: thread_id}} = Triage.create_forwarded_thread(Scope.for_user(user), conversation, items)

    assert {:ok,
            %Thread{
              forwarded_by: %{id: ^user_id},
              messages: [%{author_name: "Marta"}, %{author_name: "Fin"}, %{author_name: "Dana"}]
            }} = Triage.get_triage_thread(system_scope(), thread_id)
  end

  test "makes the thread Waiting and never queues a pass for it", %{conversation: conversation, user: user, items: items} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "triage")
    {:ok, %Thread{id: thread_id}} = Triage.create_forwarded_thread(Scope.for_user(user), conversation, items)

    refute_received {:triage_scheduled, ^thread_id, _delay}
    assert %Thread{status: :waiting} = Repo.get!(Thread, thread_id)
  end
end
