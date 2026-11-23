defmodule RailWeb.SupportLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Support
  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Schemas.IntercomWorkspace
  alias Rail.Support.Schemas.Message
  alias Rail.Tools
  alias Rail.Triage
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users

  setup %{conn: conn} do
    stub(Git, :checkout_detached_worktree, fn _project, worktree_path -> {:ok, worktree_path} end)
    stub(Git, :remove_worktree, fn _clone_path, _worktree_path -> :ok end)

    %{project: project} = triage_project()
    unique = System.unique_integer([:positive])
    app_id = "app#{unique}"

    # Attachments a pass downloads; everything else a test expects by name.
    Req.Test.stub(Rail.Intercom, fn conn ->
      assert %{method: "GET", host: "downloads.intercomcdn.com"} = conn
      Plug.Conn.send_resp(conn, 200, "file-bytes")
    end)

    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => app_id}}))

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Dishbooks Support",
        "access_token" => "tok",
        "client_id" => "cid",
        "client_secret" => "sec"
      })

    parts = [
      %{
        "id" => "p1",
        "part_type" => "comment",
        "created_at" => 1_790_000_060,
        "body" => "<p>I can help with recipes!</p>",
        "author" => %{"type" => "bot", "name" => "Fin"}
      },
      %{
        "id" => "p2",
        "part_type" => "comment",
        "created_at" => 1_790_000_120,
        "body" => "<p>The allergen sheet misses sesame.</p>",
        "author" => %{"type" => "user", "name" => "Marta Kowalczyk"},
        "attachments" => [
          %{
            "name" => "allergen-sheet.png",
            "url" => "https://downloads.intercomcdn.com/sheet.png",
            "content_type" => "image/png",
            "filesize" => 98_304
          },
          %{
            "name" => "recipe.pdf",
            "url" => "https://downloads.intercomcdn.com/recipe.pdf",
            "content_type" => "application/pdf",
            "filesize" => 188_416
          }
        ]
      },
      %{
        "id" => "p3",
        "part_type" => "note",
        "created_at" => 1_790_000_180,
        "body" => "<p>Looks like a bug.</p>",
        "author" => %{"type" => "admin", "name" => "Dana Whitfield"}
      },
      %{
        "id" => "p4",
        "part_type" => "comment",
        "created_at" => 1_790_000_240,
        "body" => "<p>Checking now.</p>",
        "author" => %{"type" => "admin", "name" => "Dana Whitfield"}
      }
    ]

    payload = %{
      "id" => "c#{unique}",
      "created_at" => 1_790_000_000,
      "updated_at" => 1_790_000_240,
      "state" => "open",
      "source" => %{
        "id" => "s1",
        "body" => "<p>How do I scale a recipe to 40 covers?</p>",
        "author" => %{"type" => "user", "name" => "Marta Kowalczyk", "email" => "marta@harbourstreetkitchen.co.uk"}
      },
      "conversation_parts" => %{"conversation_parts" => parts}
    }

    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, payload))
    {:ok, conversation} = Support.sync_intercom_conversation(workspace, payload["id"], imported: true)

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "sup_#{unique}",
        login: "sup_#{unique}",
        name: "Dana Whitfield",
        email: "sup_#{unique}@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    {:ok, tracked} = Issues.create_issue(system_scope(), project, %{title: "A recipe scales from an event's covers"})

    items = [
      %{
        "key" => "sesame",
        "kind" => "bug",
        "title" => "The allergen sheet lists sesame for tahini",
        "verdict" => "confirmed",
        "summary" => "Tahini sits under Seeds.",
        "issue" => %{
          "title" => "The allergen sheet lists sesame",
          "description" => "d",
          "priority" => "urgent",
          "estimate" => 2
        }
      },
      %{
        "key" => "pdf",
        "kind" => "bug",
        "title" => "A recipe's PDF prints the whole method",
        "verdict" => "not_reproduced",
        "issue" => %{"title" => "The PDF prints the whole method", "description" => "d", "priority" => "high"}
      },
      %{
        "key" => "scale",
        "kind" => "feature_request",
        "title" => "Scale from covers",
        "verdict" => "partly_built",
        "existing_issue" => tracked.identifier
      }
    ]

    result = %{
      "title" => "Scaling a recipe, and sesame",
      "message" => "**Sesame is a real bug.** Scaling is tracked in #{tracked.identifier}.",
      "reply" => "Hi Marta,\n\nWe've passed both on to the dev team.",
      "items" => items
    }

    pass = fn result ->
      expect(Tools, :run_agent, fn _role, _argv, _opts ->
        conversation |> Conversation.scratch_path() |> Path.join("result.json") |> File.write!(Jason.encode!(result))
        {:ok, ""}
      end)

      {:ok, _drafting} = Support.draft_support_reply(system_scope(), conversation)
      :ok = Support.run_support_agent(conversation)
    end

    link = fn user ->
      {:ok, user} =
        Users.update_user(system_scope(), user, %{
          intercom_admin_id: "7",
          intercom_app_id: app_id,
          intercom_name: "Dana W.",
          intercom_access_token: "ic-tok"
        })

      user
    end

    %{
      conn: log_in_user(conn, user),
      user: user,
      project: project,
      workspace: workspace,
      payload: payload,
      conversation: conversation,
      tracked: tracked,
      result: result,
      pass: pass,
      link: link
    }
  end

  test "the queue and the conversation show every message by who sent it, with its files", %{
    conn: conn,
    conversation: %Conversation{id: id, external_id: external_id},
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, ~p"/support")

    assert has_element?(view, "#support-filter-waiting", "Waiting · 1")
    assert has_element?(view, "#support-filter-drafting", "Drafting · 0")
    assert has_element?(view, "#support-filter-done", "Done · 0")
    assert has_element?(view, "#support-workspaces", "Intercom · Dishbooks Support")
    assert has_element?(view, "#support-row-#{id}[aria-current='true']", "Marta Kowalczyk")
    assert has_element?(view, "#support-row-#{id}", "marta@harbourstreetkitchen.co.uk")
    assert has_element?(view, "#support-row-#{id}", "How do I scale a recipe to 40 covers?")

    assert has_element?(view, "#support-conversation", "5 messages")
    assert has_element?(view, ~s(#open-in-intercom[href="#{IntercomWorkspace.inbox_url(workspace, external_id)}"]))
    assert has_element?(view, "[data-qa='support-message'][data-kind='customer']", "Customer")
    assert has_element?(view, "[data-qa='support-message'][data-kind='customer']", "MK")
    assert has_element?(view, "[data-qa='support-message'][data-kind='bot']", "BOT")
    assert has_element?(view, "[data-qa='support-message'][data-kind='bot']", "Fin")
    assert has_element?(view, "[data-qa='support-message'][data-kind='note']", "Internal note")
    assert has_element?(view, "[data-qa='support-message'][data-kind='teammate']", "Teammate")
    assert has_element?(view, "#support-conversation time[phx-hook='LocalTime']")

    assert has_element?(
             view,
             ~s(#support-conversation img[src="https://downloads.intercomcdn.com/sheet.png"][alt="allergen-sheet.png"])
           )

    assert has_element?(
             view,
             ~s(#support-conversation a[href="https://downloads.intercomcdn.com/recipe.pdf"]),
             "recipe.pdf"
           )

    assert has_element?(view, ~s(#support-conversation a[href="https://downloads.intercomcdn.com/recipe.pdf"]), "184 KB")

    assert has_element?(view, "#support-no-draft", "No draft yet. The agent has not read this conversation.")
    assert has_element?(view, "#support-chat-empty")
  end

  test "filters patch the queue, and an empty one says what is connected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/support")

    view |> element("#support-filter-done") |> render_click()
    assert_patch(view, ~p"/support?filter=done")
    assert has_element?(view, "#support-queue-empty", "No conversation is done yet.")
    assert has_element?(view, "#support-queue-empty", "Dishbooks Support is connected")
    assert has_element?(view, "#support-no-conversation", "Pick a conversation from the queue.")

    {:ok, view, _html} = live(conn, ~p"/support?filter=drafting")
    assert has_element?(view, "#support-queue-empty", "The agent is not drafting anything.")
  end

  test "with no workspace connected the queue says who adds one", %{conn: conn} do
    Repo.delete_all(IntercomWorkspace)

    {:ok, view, _html} = live(conn, ~p"/support")
    assert has_element?(view, "#support-queue-empty", "No conversation is waiting on you.")
    assert has_element?(view, "#support-queue-empty", "An admin adds one in Settings, Intercom.")
    refute has_element?(view, "#support-workspaces")
  end

  test "Draft a reply starts the agent: the reply is read-only, Send waits and the chat is off", %{
    conn: conn,
    conversation: conversation,
    pass: pass,
    result: result
  } do
    pass.(result)
    Repo.update_all(Conversation, set: [drafting_since: nil])

    {:ok, view, _html} = live(conn, ~p"/support/#{conversation.id}")
    render_click(view, "draft", %{})

    assert has_element?(view, "#support-drafting", "Running")
    assert has_element?(view, "#support-chat-running", "Running")
    assert has_element?(view, "#support-reply[readonly]")
    assert has_element?(view, "#support-send-button[disabled]")
    assert has_element?(view, "#support-chat-text[disabled]")
    assert has_element?(view, "#support-send-hint", "Send waits until the agent finishes.")
    assert has_element?(view, "#support-filter-drafting", "Drafting · 1")

    view |> form("#support-reply-form", %{"conversation" => %{"reply_text" => "Typed"}}) |> render_change()
    assert has_element?(view, "#support-send-failed", "The agent is still working on the draft.")
  end

  test "a no-draft conversation's Draft a reply button asks for a draft", %{conn: conn, conversation: conversation} do
    {:ok, view, _html} = live(conn, ~p"/support/#{conversation.id}")
    view |> element("#draft-reply-button") |> render_click()

    assert has_element?(view, "#support-drafting")
    assert %Conversation{drafting_since: %DateTime{}} = Repo.get!(Conversation, conversation.id)
  end

  test "the draft lists what goes to dev and what is tracked, and the chat shows the agent's answer", %{
    conn: conn,
    conversation: conversation,
    pass: pass,
    result: result,
    tracked: tracked
  } do
    pass.(result)

    {:ok, view, _html} = live(conn, ~p"/support/#{conversation.id}")

    assert has_element?(view, "#support-conversation-title", "Scaling a recipe, and sesame")
    assert has_element?(view, "#support-forward-list", "Forward to dev · 2")
    assert has_element?(view, "[data-qa='support-item']", "The allergen sheet lists sesame for tahini")
    assert has_element?(view, "[data-qa='support-item']", "Could not reproduce")
    assert has_element?(view, "#support-tracked", "1 not forwarded:")
    assert has_element?(view, "#support-tracked", "item 3 is tracked in")
    assert has_element?(view, "#support-tracked", "#{tracked.identifier} · #{Issue.state_label(tracked.state)}")
    assert has_element?(view, "#support-reply", "We've passed both on to the dev team.")
    assert has_element?(view, "[data-qa='support-chat-line'] strong", "Sesame is a real bug.")
    assert has_element?(view, "[data-qa='support-chat-line']", "Added item 1 · Added item 2 · Added item 3")
    refute has_element?(view, "[data-qa='support-item']", "Mark done")
  end

  test "unlinked, Send is disabled with a prompt to link, and a send says why", %{
    conn: conn,
    conversation: conversation,
    pass: pass,
    result: result
  } do
    pass.(result)
    {:ok, view, _html} = live(conn, ~p"/support/#{conversation.id}")

    assert has_element?(view, "#support-link-prompt", "Link your Intercom account to send this as yourself.")
    assert has_element?(view, ~s(#link-intercom[href="/settings/connected-accounts"]))
    assert has_element?(view, "#support-send-button[disabled]", "Send reply & forward 2 to dev")
    assert has_element?(view, "#support-send-hint", "Posts in Intercom as you, then forwards to triage.")

    render_click(view, "send", %{})
    assert has_element?(view, "#support-send-failed", "Link your Intercom account to send this as yourself.")
  end

  test "linking in another tab enables Send, and someone else's change is ignored", %{
    conn: conn,
    conversation: conversation,
    pass: pass,
    result: result,
    user: user,
    link: link
  } do
    pass.(result)
    {:ok, view, _html} = live(conn, ~p"/support/#{conversation.id}")
    assert has_element?(view, "#support-link-prompt")

    send(view.pid, {:users_changed, "usr_someone_else"})
    assert has_element?(view, "#support-link-prompt")

    link.(user)
    send(view.pid, {:users_changed, user.id})

    refute has_element?(view, "#support-link-prompt")
    assert has_element?(view, "#support-send-hint", "Posts in Intercom as Dana W., then forwards 2 to triage.")
    refute has_element?(view, "#support-send-button[disabled]")
    assert has_element?(view, "#support-send-button[data-no-repeat] .pi-paper-plane-tilt-bold")
  end

  test "Send posts the reply once as the person and forwards to triage, then waits for Mark done", %{
    conn: conn,
    conversation: conversation,
    pass: pass,
    result: result,
    user: user,
    link: link
  } do
    pass.(result)
    link.(user)
    {:ok, view, _html} = live(conn, ~p"/support/#{conversation.id}")

    view
    |> form("#support-reply-form", %{"conversation" => %{"reply_text" => "Hi Marta,\n\nPassed on."}})
    |> render_change()

    assert %Conversation{reply_text: "Hi Marta,\n\nPassed on."} = Repo.get!(Conversation, conversation.id)

    Req.Test.allow(Rail.Intercom, self(), view.pid)

    Req.Test.expect(Rail.Intercom, fn conn ->
      assert %{method: "POST", request_path: "/conversations/" <> _reply} = conn
      assert ["Bearer ic-tok"] = Plug.Conn.get_req_header(conn, "authorization")
      Req.Test.json(conn, %{"type" => "conversation"})
    end)

    view |> element("#support-send-button", "Send reply & forward 2 to dev") |> render_click()

    assert has_element?(view, "#support-sent", "Sent by Dana Whitfield")
    assert has_element?(view, "#support-sent", "and forwarded 2 to dev")
    assert [%Thread{status: :waiting}] = Repo.all(Thread)

    view |> element("#mark-done-button") |> render_click()
    assert has_element?(view, "#support-done", "Marked done by Dana Whitfield")
    assert has_element?(view, "#support-done", "A new message from the customer brings it back to Waiting.")
    assert has_element?(view, "#support-filter-done", "Done · 1")
  end

  test "a reply Intercom refuses says nothing went out", %{
    conn: conn,
    conversation: conversation,
    pass: pass,
    result: result,
    user: user,
    link: link
  } do
    pass.(result)
    link.(user)
    {:ok, view, _html} = live(conn, ~p"/support/#{conversation.id}")
    Req.Test.allow(Rail.Intercom, self(), view.pid)
    Req.Test.expect(Rail.Intercom, &Plug.Conn.send_resp(&1, 500, "{}"))

    view |> element("#support-send-button") |> render_click()

    assert has_element?(view, "#support-send-failed", "Intercom did not take the reply")
    assert %Conversation{reply_posted_at: nil} = Repo.get!(Conversation, conversation.id)
  end

  test "a forward that fails after the reply posted says so, and the retry only forwards", %{
    conn: conn,
    conversation: conversation,
    pass: pass,
    result: result,
    user: user,
    link: link
  } do
    pass.(result)
    link.(user)
    {:ok, view, _html} = live(conn, ~p"/support/#{conversation.id}")
    Req.Test.allow(Rail.Intercom, self(), view.pid)
    allow(Triage, self(), view.pid)
    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"type" => "conversation"}))
    expect(Triage, :create_forwarded_thread, fn _scope, _conversation, _items -> {:error, :boom} end)

    view |> element("#support-send-button") |> render_click()

    assert has_element?(view, "#support-send-error", "Posted the reply in Intercom, but could not forward to triage.")
    assert has_element?(view, "#support-send-button", "Forward 2 to dev")
    assert has_element?(view, "[data-qa='support-item']", "Not forwarded yet")
    assert has_element?(view, "#support-send-hint", "The reply is already in Intercom.")
    assert has_element?(view, "#support-reply[readonly]")
    refute has_element?(view, "#mark-done-button")
    refute has_element?(view, "#support-send-failed")

    expect(Triage, :create_forwarded_thread, fn scope, conversation, items ->
      call_original(Triage, :create_forwarded_thread, [scope, conversation, items])
    end)

    view |> element("#support-send-button", "Forward 2 to dev") |> render_click()
    assert has_element?(view, "#support-sent", "and forwarded 2 to dev")
  end

  test "a failed pass keeps the draft, says why and can be tried again", %{
    conn: conn,
    conversation: conversation,
    pass: pass,
    result: result
  } do
    pass.(result)
    expect(Tools, :run_agent, fn _role, _argv, _opts -> {:error, :timeout} end)
    {:ok, _drafting} = Support.draft_support_reply(system_scope(), conversation)
    :ok = Support.run_support_agent(conversation)

    {:ok, view, _html} = live(conn, ~p"/support/#{conversation.id}")
    assert has_element?(view, "#support-agent-error", "The agent did not finish.")
    assert has_element?(view, "#support-agent-error", "still running after 30 minutes")
    assert has_element?(view, "#support-send-hint", "The draft above is from the agent's last finished run.")
    assert has_element?(view, "#support-reply", "We've passed both on to the dev team.")

    view |> element("#try-again-button") |> render_click()
    assert has_element?(view, "#support-drafting")
    refute has_element?(view, "#support-agent-error")
  end

  test "a first pass that failed says no reply is drafted yet", %{conn: conn, conversation: conversation} do
    expect(Tools, :run_agent, fn _role, _argv, _opts -> {:error, :timeout} end)
    {:ok, _drafting} = Support.draft_support_reply(system_scope(), conversation)
    :ok = Support.run_support_agent(conversation)

    {:ok, view, _html} = live(conn, ~p"/support/#{conversation.id}")
    assert has_element?(view, "#support-agent-error", "The agent did not finish.")
    assert has_element?(view, "#support-send-hint", "The agent has not drafted a reply yet.")
  end

  test "the queue names only the workspaces of the projects in view", %{conn: conn, github_project: github_project} do
    unique = System.unique_integer([:positive])
    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => "other_#{unique}"}}))

    {:ok, _other} =
      Support.create_intercom_workspace(system_scope(), github_project, %{
        "name" => "Other Support #{unique}",
        "access_token" => "tok",
        "client_id" => "cid",
        "client_secret" => "sec"
      })

    {:ok, view, _html} = live(conn, ~p"/support")
    assert has_element?(view, "#support-workspaces", "Intercom · Dishbooks Support")
    refute render(view) =~ "Other Support"
  end

  test "a posted reply's form sent back unchanged, as a reconnect does, shows no error", %{
    conn: conn,
    conversation: conversation,
    pass: pass,
    result: result,
    user: user,
    link: link
  } do
    pass.(result)
    link.(user)
    {:ok, view, _html} = live(conn, ~p"/support/#{conversation.id}")
    Req.Test.allow(Rail.Intercom, self(), view.pid)
    allow(Triage, self(), view.pid)
    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"type" => "conversation"}))
    expect(Triage, :create_forwarded_thread, fn _scope, _conversation, _items -> {:error, :boom} end)
    view |> element("#support-send-button") |> render_click()

    view
    |> form("#support-reply-form", %{
      "conversation" => %{"reply_text" => "Hi Marta,\r\n\r\nWe've passed both on to the dev team."}
    })
    |> render_change()

    refute has_element?(view, "#support-send-failed")
    assert has_element?(view, "#support-send-error", "Posted the reply in Intercom, but could not forward to triage.")

    view |> form("#support-reply-form", %{"conversation" => %{"reply_text" => "Changed"}}) |> render_change()
    assert has_element?(view, "#support-send-failed", "This reply is already being sent, or was sent.")
  end

  test "a chat message is added and starts the agent; a blank one is refused; typing survives a reload", %{
    conn: conn,
    conversation: conversation,
    pass: pass,
    result: result
  } do
    pass.(result)
    {:ok, view, _html} = live(conn, ~p"/support/#{conversation.id}")

    view |> form("#support-chat-form", %{"chat_message" => %{"text" => "Drop the"}}) |> render_change()
    send(view.pid, :reload)
    assert has_element?(view, "#support-chat-text", "Drop the")

    view |> form("#support-chat-form", %{"chat_message" => %{"text" => "   "}}) |> render_submit()
    assert has_element?(view, "#support-chat-form")
    refute has_element?(view, "#support-drafting")

    view |> form("#support-chat-form", %{"chat_message" => %{"text" => "Drop the workaround."}}) |> render_submit()

    assert has_element?(view, "[data-qa='support-chat-line']", "Dana Whitfield")
    assert has_element?(view, "[data-qa='support-chat-line']", "Drop the workaround.")
    assert has_element?(view, "#support-drafting")
    refute has_element?(view, "#support-chat-text", "Drop the")
  end

  test "a chat from a tab that has lost the project finds the conversation gone", %{
    conn: conn,
    conversation: conversation,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/support/#{conversation.id}")

    # Access taken away before this tab heard of it.
    :sys.replace_state(view.pid, fn state ->
      put_in(state.socket.assigns.current_scope, Rail.Scope.for_user(%{user | project_ids: []}))
    end)

    view |> form("#support-chat-form", %{"chat_message" => %{"text" => "Anything?"}}) |> render_submit()
    assert has_element?(view, "#support-no-conversation")
  end

  test "Mark done from the no-draft state, and an import closed in Intercom reads as such", %{
    conn: conn,
    conversation: conversation,
    workspace: workspace,
    payload: payload
  } do
    {:ok, view, _html} = live(conn, ~p"/support/#{conversation.id}")
    view |> element("#mark-done-button") |> render_click()
    assert has_element?(view, "#support-done", "Marked done by Dana Whitfield")

    closed = %{payload | "id" => "closed#{conversation.id}", "state" => "closed"}
    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, closed))
    {:ok, imported} = Support.sync_intercom_conversation(workspace, closed["id"], imported: true)

    {:ok, view, _html} = live(conn, ~p"/support/#{imported.id}?filter=done")
    assert has_element?(view, "#support-done", "Closed in Intercom before it was imported.")
  end

  test "an open page shows a new customer message after a sync, without a reload", %{
    conn: conn,
    conversation: conversation,
    workspace: workspace,
    payload: payload
  } do
    {:ok, view, _html} = live(conn, ~p"/support/#{conversation.id}")
    send(view.pid, {:unrelated, 1})

    newer = %{
      "id" => "p5",
      "part_type" => "comment",
      "created_at" => 1_790_000_900,
      "body" => "<p>The sesame thing also shows on the menu card.</p>",
      "author" => %{"type" => "user", "name" => "Marta Kowalczyk"}
    }

    payload =
      payload
      |> Map.put("updated_at", 1_790_000_900)
      |> update_in(["conversation_parts", "conversation_parts"], &List.insert_at(&1, -1, newer))

    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, payload))
    {:ok, _synced} = Support.sync_intercom_conversation(workspace, payload["id"])
    # A second announcement while the first reload waits schedules no other.
    send(view.pid, {:intercom_workspace_changed, workspace.id})

    eventually(fn -> assert has_element?(view, "#support-conversation", "also shows on the menu card") end, 4_000)
    assert has_element?(view, "#support-conversation", "6 messages")
  end

  test "someone with no name reads by login, and a person no longer in Rail reads as support", %{
    conn: conn,
    conversation: conversation,
    project: project,
    pass: pass,
    result: result,
    link: link
  } do
    pass.(result)
    unique = System.unique_integer([:positive])

    {:ok, nameless} =
      Users.register_oauth_user(%{github_id: "nn_#{unique}", login: "nn_#{unique}", email: "nn_#{unique}@x.com"})

    {:ok, nameless} = Users.update_user(system_scope(), nameless, %{project_ids: [project.id]})
    nameless = link.(nameless)
    scope = Rail.Scope.for_user(nameless)

    {:ok, _line} = Support.send_support_chat(scope, conversation, %{"text" => "Shorter, please."})
    Repo.update_all(Conversation, set: [drafting_since: nil])
    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"type" => "conversation"}))
    {:ok, _sent} = Support.send_support_reply(scope, conversation)
    [%Thread{id: thread_id}] = Repo.all(Thread)

    {:ok, view, _html} = live(conn, ~p"/support/#{conversation.id}")
    assert has_element?(view, "#support-sent", "Sent by nn_#{unique}")
    assert has_element?(view, "[data-qa='support-chat-line']", "nn_#{unique}")

    {:ok, triage, _html} = live(conn, ~p"/triage/#{thread_id}")
    assert has_element?(triage, "#forwarded-note", "Forwarded by nn_#{unique}")

    Repo.delete!(nameless)

    {:ok, view, _html} = live(conn, ~p"/support/#{conversation.id}")
    assert has_element?(view, "#support-sent", "Sent by someone")
    assert has_element?(view, "[data-qa='support-chat-line']", "Support")

    {:ok, triage, _html} = live(conn, ~p"/triage/#{thread_id}")
    assert has_element?(triage, "#forwarded-note", "Forwarded by support")
    assert has_element?(triage, "#triage-row-#{thread_id}", "Forwarded by support")
  end

  test "the message box sends to the customer while the agent drafts, leaves the draft alone and clears", %{
    conn: conn,
    conversation: conversation,
    user: user,
    link: link
  } do
    link.(user)
    {:ok, _drafting} = Support.draft_support_reply(system_scope(), conversation)
    {:ok, view, _html} = live(conn, ~p"/support/#{conversation.id}")

    assert has_element?(view, "#support-messages[phx-hook='ChatAutoscroll'][data-run-id='#{conversation.id}']")
    assert has_element?(view, "#support-drafting")
    assert has_element?(view, ~s(#support-message-text[placeholder="Message Marta Kowalczyk in Intercom as Dana W."]))
    refute has_element?(view, "#support-message-text[disabled]")
    # LiveView puts a phx-disable-with button back by its text alone, which drops the icon.
    refute has_element?(view, "#support-message-send[phx-disable-with]")
    assert has_element?(view, "#support-message-send .pi-paper-plane-tilt-bold")

    view |> form("#support-message-form", %{"support_message" => %{"text" => "One more thing"}}) |> render_change()
    send(view.pid, :reload)
    assert has_element?(view, "#support-message-text", "One more thing")

    Req.Test.allow(Rail.Intercom, self(), view.pid)

    Req.Test.expect(Rail.Intercom, fn conn ->
      assert %{method: "POST", request_path: "/conversations/" <> _reply} = conn
      assert ["Bearer ic-tok"] = Plug.Conn.get_req_header(conn, "authorization")
      assert %{"body" => "<p>One more thing</p>"} = conn |> Req.Test.raw_body() |> Jason.decode!()
      Req.Test.json(conn, %{"type" => "conversation"})
    end)

    view |> form("#support-message-form", %{"support_message" => %{"text" => "One more thing"}}) |> render_submit()

    refute has_element?(view, "#support-message-text", "One more thing")
    refute has_element?(view, "#support-message-failed")
    assert has_element?(view, "#support-drafting")
    assert %Conversation{drafting_since: %DateTime{}, reply_posted_at: nil} = Repo.get!(Conversation, conversation.id)
  end

  test "a message Intercom refuses keeps the text and says nothing went out; a blank one says to write one", %{
    conn: conn,
    conversation: conversation,
    user: user,
    link: link
  } do
    link.(user)
    {:ok, view, _html} = live(conn, ~p"/support/#{conversation.id}")
    Req.Test.allow(Rail.Intercom, self(), view.pid)
    Req.Test.expect(Rail.Intercom, &Plug.Conn.send_resp(&1, 500, "{}"))

    view |> form("#support-message-form", %{"support_message" => %{"text" => "Hi Marta"}}) |> render_submit()

    assert has_element?(view, "#support-message-failed", "Intercom did not take the message, so nothing was sent.")
    assert has_element?(view, "#support-message-text", "Hi Marta")

    view |> form("#support-message-form", %{"support_message" => %{"text" => "  "}}) |> render_submit()
    assert has_element?(view, "#support-message-failed", "Write a message first.")
  end

  test "unlinked, the message box is off with a prompt to link, and a send says why", %{
    conn: conn,
    conversation: conversation
  } do
    {:ok, view, _html} = live(conn, ~p"/support/#{conversation.id}")

    assert has_element?(view, "#support-message-text[disabled]")
    assert has_element?(view, "#support-message-send[disabled]")
    assert has_element?(view, "#support-message-link-prompt", "Link your Intercom account to message Marta Kowalczyk")
    assert has_element?(view, ~s(#support-message-link-intercom[href="/settings/connected-accounts"]))

    render_submit(view, "send_message", %{"support_message" => %{"text" => "Hi"}})
    assert has_element?(view, "#support-message-failed", "Link your Intercom account to send this as yourself.")
  end

  test "an image opens enlarged over the page, stays put at either end and closes", %{
    conn: conn,
    conversation: conversation
  } do
    %Message{id: message_id} = Repo.get_by!(Message, conversation_id: conversation.id, external_id: "p2")
    {:ok, view, _html} = live(conn, ~p"/support/#{conversation.id}")

    render_hook(view, "step_image", %{"direction" => "next"})
    refute has_element?(view, "#support-image-view")

    view |> element("#support-image-#{message_id}-0") |> render_click()

    assert has_element?(view, "#support-image-view [role='dialog'][aria-label='allergen-sheet.png']")
    assert has_element?(view, "#support-image-name", "allergen-sheet.png")
    assert has_element?(view, ~s(#support-image-original[href="https://downloads.intercomcdn.com/sheet.png"]))
    refute has_element?(view, "#support-image-previous")

    for {event, params} <- [
          {"step_image", %{"direction" => "next"}},
          {"step_image", %{"direction" => "previous"}},
          {"image_key", %{"key" => "ArrowRight"}},
          {"image_key", %{"key" => "ArrowLeft"}},
          {"image_key", %{"key" => "Enter"}}
        ] do
      render_hook(view, event, params)
      assert has_element?(view, "#support-image-name", "allergen-sheet.png")
    end

    send(view.pid, :reload)
    assert has_element?(view, "#support-image-view")

    view |> element("#support-image-close") |> render_click()
    refute has_element?(view, "#support-image-view")

    render_hook(view, "open_image", %{"message_id" => "smg_gone", "index" => "0"})
    refute has_element?(view, "#support-image-view")
  end
end
