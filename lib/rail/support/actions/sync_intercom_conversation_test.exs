defmodule Rail.Support.Actions.SyncIntercomConversationTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Intercom
  alias Rail.Repo
  alias Rail.Support
  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Schemas.Message
  alias Rail.Support.Schemas.Message.Attachment
  alias Rail.Support.Workers.RunSupportAgent
  alias Rail.Users

  setup %{project: project} do
    unique = System.unique_integer([:positive])
    Req.Test.expect(Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => "app_#{unique}"}}))

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Support",
        "access_token" => "tok_ws",
        "client_id" => "cid",
        "client_secret" => "sec"
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "sync_#{unique}",
        login: "sync_#{unique}",
        name: "Dana Whitfield",
        email: "sync_#{unique}@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})

    payload = %{
      "id" => "c#{unique}",
      "created_at" => 1_790_000_000,
      "updated_at" => 1_790_000_500,
      "state" => "open",
      "source" => %{
        "id" => "src1",
        "subject" => "<p>Allergen sheet</p>",
        "author" => %{"type" => "user", "name" => "Marta Kowalczyk", "email" => "marta@example.com"},
        "body" => "<p>The sheet misses sesame.</p>",
        "attachments" => [
          %{
            "url" => "https://downloads.intercomcdn.com/r.pdf",
            "name" => "r.pdf",
            "content_type" => "application/pdf",
            "filesize" => 2048
          }
        ]
      },
      "conversation_parts" => %{
        "conversation_parts" => [
          %{
            "id" => "p1",
            "part_type" => "comment",
            "created_at" => 1_790_000_100,
            "author" => %{"type" => "bot", "name" => "Fin"},
            "body" => "<p>Did that help?</p>"
          },
          %{
            "id" => "p2",
            "part_type" => "note",
            "created_at" => 1_790_000_200,
            "author" => %{"type" => "admin", "name" => "Dana Whitfield"},
            "body" => "<p>Looks like a bug.</p>"
          },
          %{
            "id" => "p3",
            "part_type" => "assignment",
            "created_at" => 1_790_000_250,
            "author" => %{"type" => "admin"},
            "body" => nil
          },
          %{
            "id" => "p4",
            "part_type" => "comment",
            "created_at" => 1_790_000_300,
            "author" => %{"type" => "user", "name" => "Marta Kowalczyk"},
            "body" => "<p>Screenshot:</p><img src=\"https://downloads.intercomcdn.com/i/shot.png\">"
          },
          %{
            "id" => "p5",
            "part_type" => "comment",
            "created_at" => 1_790_000_400,
            "author" => %{"type" => "admin", "name" => "Dana Whitfield"},
            "body" => "<p>Thanks, on it.</p>"
          }
        ]
      }
    }

    %{workspace: workspace, user: user, payload: payload, external_id: payload["id"]}
  end

  test "stores every part with its kind and attachments, and a second read keeps one row per part", %{
    workspace: %{id: workspace_id} = workspace,
    payload: payload,
    external_id: external_id,
    project: %{id: project_id}
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "support")
    Req.Test.stub(Intercom, &Req.Test.json(&1, payload))

    assert {:ok,
            %Conversation{
              id: conversation_id,
              project_id: ^project_id,
              intercom_workspace_id: ^workspace_id,
              external_id: ^external_id,
              status: :waiting,
              title: "Allergen sheet",
              customer_name: "Marta Kowalczyk",
              customer_email: "marta@example.com",
              last_message_at: ~U[2026-09-21 14:20:00.000000Z],
              intercom_updated_at: ~U[2026-09-21 14:21:40.000000Z],
              drafting_since: nil
            }} = Support.sync_intercom_conversation(workspace, external_id)

    assert_receive {:support_changed, ^conversation_id}
    assert {:ok, _again} = Support.sync_intercom_conversation(workspace, external_id)

    assert [
             %Message{
               external_id: "src1",
               kind: :customer,
               text: "The sheet misses sesame.",
               attachments: [%Attachment{name: "r.pdf", content_type: "application/pdf", size: 2048}]
             },
             %Message{external_id: "p1", kind: :bot, author_name: "Fin"},
             %Message{external_id: "p2", kind: :note, author_name: "Dana Whitfield"},
             %Message{
               external_id: "p4",
               kind: :customer,
               text: "Screenshot:",
               attachments: [%Attachment{name: "shot.png", content_type: "image/*"}]
             },
             %Message{external_id: "p5", kind: :teammate, text: "Thanks, on it."}
           ] = Repo.all(from m in Message, where: m.conversation_id == ^conversation_id, order_by: m.posted_at)

    refute_enqueued(worker: RunSupportAgent)
  end

  test "an older read than the stored one leaves the conversation as it was", %{
    workspace: workspace,
    payload: payload,
    external_id: external_id
  } do
    Req.Test.expect(Intercom, &Req.Test.json(&1, payload))
    assert {:ok, %Conversation{id: conversation_id}} = Support.sync_intercom_conversation(workspace, external_id)

    older = %{payload | "updated_at" => 1_790_000_400, "source" => %{payload["source"] | "subject" => "Stale"}}
    Req.Test.expect(Intercom, &Req.Test.json(&1, older))

    assert {:ok, %Conversation{title: "Allergen sheet", intercom_updated_at: ~U[2026-09-21 14:21:40.000000Z]}} =
             Support.sync_intercom_conversation(workspace, external_id)

    assert %Conversation{title: "Allergen sheet"} = Repo.get!(Conversation, conversation_id)
  end

  test "the import puts a conversation Intercom closed in Done, with no one as its marker", %{
    workspace: workspace,
    payload: payload,
    external_id: external_id
  } do
    Req.Test.expect(Intercom, &Req.Test.json(&1, %{payload | "state" => "closed"}))

    assert {:ok, %Conversation{status: :done, done_by_id: nil, done_at: ~U[2026-09-21 14:21:40.000000Z]}} =
             Support.sync_intercom_conversation(workspace, external_id, imported: true)
  end

  test "the import puts an open conversation in Waiting", %{
    workspace: workspace,
    payload: payload,
    external_id: external_id
  } do
    Req.Test.expect(Intercom, &Req.Test.json(&1, payload))

    assert {:ok, %Conversation{status: :waiting, done_at: nil}} =
             Support.sync_intercom_conversation(workspace, external_id, imported: true)
  end

  test "a conversation a webhook brings in starts Waiting even if Intercom already closed it", %{
    workspace: workspace,
    payload: payload,
    external_id: external_id
  } do
    Req.Test.expect(Intercom, &Req.Test.json(&1, %{payload | "state" => "closed"}))

    assert {:ok, %Conversation{status: :waiting}} = Support.sync_intercom_conversation(workspace, external_id)
  end

  test "a teammate reply or Intercom closing it leaves a Waiting conversation Waiting", %{
    workspace: workspace,
    payload: payload,
    external_id: external_id
  } do
    Req.Test.expect(Intercom, &Req.Test.json(&1, payload))
    assert {:ok, %Conversation{status: :waiting}} = Support.sync_intercom_conversation(workspace, external_id)

    teammate = %{
      "id" => "p6",
      "part_type" => "close",
      "created_at" => 1_790_000_600,
      "author" => %{"type" => "admin", "name" => "Dana"},
      "body" => "<p>Closing.</p>"
    }

    closed = %{payload | "state" => "closed", "updated_at" => 1_790_000_600}

    closed =
      put_in(
        closed,
        ["conversation_parts", "conversation_parts"],
        [teammate | payload["conversation_parts"]["conversation_parts"]]
      )

    Req.Test.expect(Intercom, &Req.Test.json(&1, closed))

    assert {:ok, %Conversation{status: :waiting}} =
             Support.sync_intercom_conversation(workspace, external_id, imported: true)
  end

  test "Mark done holds until the customer writes again, and their message takes it back to Waiting", %{
    workspace: workspace,
    payload: payload,
    external_id: external_id,
    user: user
  } do
    Req.Test.expect(Intercom, &Req.Test.json(&1, payload))
    assert {:ok, conversation} = Support.sync_intercom_conversation(workspace, external_id)
    assert {:ok, %Conversation{status: :done}} = Support.mark_support_done(Rail.Scope.for_user(user), conversation)

    later = DateTime.to_unix(DateTime.utc_now()) + 60
    parts = payload["conversation_parts"]["conversation_parts"]

    teammate = %{
      "id" => "p7",
      "part_type" => "comment",
      "created_at" => later,
      "author" => %{"type" => "admin", "name" => "Dana"},
      "body" => "Bye"
    }

    Req.Test.expect(
      Intercom,
      &Req.Test.json(
        &1,
        put_in(%{payload | "updated_at" => later}, ["conversation_parts", "conversation_parts"], [teammate | parts])
      )
    )

    assert {:ok, %Conversation{status: :done}} = Support.sync_intercom_conversation(workspace, external_id)

    customer = %{
      "id" => "p8",
      "part_type" => "comment",
      "created_at" => later + 1,
      "author" => %{"type" => "user", "name" => "Marta"},
      "body" => "One more"
    }

    reopened =
      put_in(
        %{payload | "updated_at" => later + 1},
        ["conversation_parts", "conversation_parts"],
        [customer, teammate | parts]
      )

    Req.Test.expect(Intercom, &Req.Test.json(&1, reopened))

    assert {:ok, %Conversation{status: :waiting, done_at: nil, done_by_id: nil}} =
             Support.sync_intercom_conversation(workspace, external_id)
  end

  test "a customer message after the posted reply opens a new round", %{
    workspace: workspace,
    payload: payload,
    external_id: external_id,
    user: %{id: user_id}
  } do
    Req.Test.expect(Intercom, &Req.Test.json(&1, payload))
    assert {:ok, %Conversation{id: conversation_id}} = Support.sync_intercom_conversation(workspace, external_id)

    posted_at = ~U[2026-09-21 14:25:00.000000Z]

    Repo.update_all(from(c in Conversation, where: c.id == ^conversation_id),
      set: [reply_posted_at: posted_at, reply_posted_by_id: user_id, send_error: "x"]
    )

    Req.Test.expect(Intercom, &Req.Test.json(&1, %{payload | "updated_at" => 1_790_000_600}))

    assert {:ok, %Conversation{reply_posted_at: ^posted_at}} =
             Support.sync_intercom_conversation(workspace, external_id)

    customer = %{
      "id" => "p9",
      "part_type" => "comment",
      "created_at" => 1_790_001_000,
      "author" => %{"type" => "user"},
      "body" => "Still broken"
    }

    parts = [customer | payload["conversation_parts"]["conversation_parts"]]

    Req.Test.expect(
      Intercom,
      &Req.Test.json(
        &1,
        put_in(%{payload | "updated_at" => 1_790_001_000}, ["conversation_parts", "conversation_parts"], parts)
      )
    )

    assert {:ok, %Conversation{reply_posted_at: nil, reply_posted_by_id: nil, send_error: nil}} =
             Support.sync_intercom_conversation(workspace, external_id)
  end

  test "a customer's new message asks for one draft, however often it is read", %{
    workspace: workspace,
    payload: payload,
    external_id: external_id
  } do
    Req.Test.stub(Intercom, &Req.Test.json(&1, payload))

    assert {:ok, %Conversation{id: conversation_id, drafting_since: %DateTime{} = since}} =
             Support.sync_intercom_conversation(workspace, external_id, draft: true)

    assert {:ok, %Conversation{drafting_since: ^since}} =
             Support.sync_intercom_conversation(workspace, external_id, draft: true)

    assert [%Oban.Job{args: %{"conversation_id" => ^conversation_id}}] = all_enqueued(worker: RunSupportAgent)
  end

  test "nothing newer from the customer than the last draft, or a Done conversation, asks for none", %{
    workspace: workspace,
    payload: payload,
    external_id: external_id,
    user: user
  } do
    Req.Test.stub(Intercom, &Req.Test.json(&1, payload))

    assert {:ok, %Conversation{id: conversation_id} = conversation} =
             Support.sync_intercom_conversation(workspace, external_id)

    Repo.update_all(from(c in Conversation, where: c.id == ^conversation_id), set: [drafted_at: DateTime.utc_now()])

    assert {:ok, %Conversation{drafting_since: nil}} =
             Support.sync_intercom_conversation(workspace, external_id, draft: true)

    Repo.update_all(from(c in Conversation, where: c.id == ^conversation_id), set: [drafted_at: nil])
    {:ok, _done} = Support.mark_support_done(Rail.Scope.for_user(user), conversation)

    assert {:ok, %Conversation{drafting_since: nil}} =
             Support.sync_intercom_conversation(workspace, external_id, draft: true)

    refute_enqueued(worker: RunSupportAgent)
  end

  test "a conversation with no customer message asks for no draft", %{
    workspace: workspace,
    payload: payload,
    external_id: external_id
  } do
    outbound = %{
      payload
      | "source" => %{
          "id" => "src1",
          "author" => %{"type" => "admin", "name" => "Dana"},
          "body" => "<p>Hello from us</p>"
        },
        "conversation_parts" => nil
    }

    Req.Test.expect(Intercom, &Req.Test.json(&1, outbound))

    assert {:ok, %Conversation{drafting_since: nil, customer_name: nil, title: nil}} =
             Support.sync_intercom_conversation(workspace, external_id, draft: true)

    refute_enqueued(worker: RunSupportAgent)
  end

  test "a conversation a teammate started names the customer who answered, with no email", %{
    workspace: workspace,
    payload: payload,
    external_id: external_id
  } do
    outbound = %{
      payload
      | "source" => %{
          "id" => "src1",
          "author" => %{"type" => "admin", "name" => "Priya", "email" => "priya@acme.test"},
          "body" => "<p>Hello</p>"
        },
        "conversation_parts" => %{
          "conversation_parts" => [
            %{
              "id" => "p1",
              "part_type" => "comment",
              "created_at" => 1_790_000_100,
              "body" => "<p>Hi</p>",
              "author" => %{"type" => "user", "name" => "Owen Price", "email" => "owen@pier9.test"}
            }
          ]
        }
    }

    Req.Test.expect(Intercom, &Req.Test.json(&1, outbound))

    assert {:ok, %Conversation{customer_name: "Owen Price", customer_email: nil}} =
             Support.sync_intercom_conversation(workspace, external_id)
  end

  test "the title only changes when Intercom has a subject", %{
    workspace: workspace,
    payload: payload,
    external_id: external_id
  } do
    Req.Test.expect(Intercom, &Req.Test.json(&1, payload))
    assert {:ok, %Conversation{title: "Allergen sheet"}} = Support.sync_intercom_conversation(workspace, external_id)

    for subject <- [nil, "<p> </p>"] do
      Req.Test.expect(Intercom, &Req.Test.json(&1, %{payload | "source" => %{payload["source"] | "subject" => subject}}))
      assert {:ok, %Conversation{title: "Allergen sheet"}} = Support.sync_intercom_conversation(workspace, external_id)
    end
  end

  test "a conversation with no messages at all is still mirrored", %{workspace: workspace, external_id: external_id} do
    Req.Test.expect(Intercom, &Req.Test.json(&1, %{"id" => external_id, "updated_at" => 1_790_000_000}))

    assert {:ok, %Conversation{last_message_at: nil, customer_name: nil}} =
             Support.sync_intercom_conversation(workspace, external_id)
  end

  test "a conversation Intercom will not hand over is an error", %{workspace: workspace} do
    Req.Test.expect(Intercom, &Plug.Conn.send_resp(&1, 404, "gone"))

    assert {:error, {:intercom_error, 404, "gone"}} = Support.sync_intercom_conversation(workspace, 12_345)
  end
end
