defmodule RailWeb.TriageLiveTest do
  use RailWeb.ConnCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Repo
  alias Rail.Support
  alias Rail.Support.Schemas.Conversation
  alias Rail.Tools
  alias Rail.Triage
  alias Rail.Triage.Schemas.ChatMessage
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users

  setup %{conn: conn} do
    # What is merged is read from the project's clone, and a pass checks the default branch out, all through
    # Rail.Git. The project has no clone, so these see nothing on the default branch, as when there is none.
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)
    stub(Git, :list_default_branch_paths, fn _project, paths -> if paths == [], do: MapSet.new() end)
    stub(Git, :checkout_detached_worktree, fn _project, worktree_path -> {:ok, worktree_path} end)
    stub(Git, :remove_worktree, fn _clone_path, _worktree_path -> :ok end)

    %{project: project} = triage_project()
    %{workspace: workspace, channel: channel} = connect_slack_channel(project, users: %{"U_PRIYA" => "Priya Natarajan"})

    {:ok, %Issue{identifier: tracked} = existing} =
      Issues.create_issue(system_scope(), project, %{title: "Ruling a finding scrolls the list to the top"})

    {:ok, thread} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{
          "text" => "Approved BILL-88 and it sits at Design. Could Up next show wait times? And the list jumps."
        })
      )

    request = %{
      "key" => "wait-times",
      "kind" => "feature_request",
      "title" => "Wait time on every Up next row",
      "verdict" => "partly_built",
      "summary" => "Ordered by wait, but rows show none.",
      "evidence" => [%{"file" => "lib/up_next.ex", "lines" => "78", "excerpt" => "Rows show no wait.", "holds" => false}],
      "issue" => %{"title" => "Every Up next row shows its wait", "priority" => "low", "estimate" => 2}
    }

    covered = %{
      "key" => "list-jumps",
      "kind" => "bug",
      "title" => "The findings list jumps on ruling",
      "verdict" => "confirmed",
      "existing_issue" => tracked,
      "followup" => "Priya hit it too, on BILL-88."
    }

    thread =
      triage_with(
        thread,
        triage_result([triage_bug(), request, covered], %{
          "title" => "Tasks stuck at Design, wait times in Up next",
          "message" => "Three items. One is already tracked.",
          "reply" => "Thanks Priya, we reproduced the first and filed both.",
          "messages" => [
            %{
              "ts" => thread.external_id,
              "items" => [
                %{
                  "key" => "stuck-at-design",
                  "change" => "raised",
                  "passage" => "Approved BILL-88 and it sits at Design."
                },
                %{"key" => "wait-times", "change" => "raised", "passage" => "Could Up next show wait times?"}
              ]
            }
          ]
        })
      )

    user = slack_user(workspace.external_id, "Michael")
    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})

    %{
      conn: log_in_user(conn, user),
      user: user,
      project: project,
      workspace: workspace,
      channel: channel,
      thread: thread,
      existing: existing
    }
  end

  test "a role without the Triage tab is sent to its own first tab", %{conn: conn} do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "triage_live_role_#{id}",
        login: "triage_live-role-#{id}",
        email: "triage_live_role_#{id}@example.com"
      })

    for {role, home} <- [tester: "/testing", support: "/support"] do
      {:ok, user} = Users.update_user(system_scope(), user, %{role: role})

      assert {:error, {:redirect, %{to: ^home}}} = live(log_in_user(conn, user), ~p"/triage")
    end
  end

  test "shows one reply, a card per item, the chat, and Send naming each part, with no evidence or assumptions", %{
    conn: conn,
    project: project,
    existing: existing,
    thread: %Thread{id: thread_id, items: [bug, request, covered]}
  } do
    {:ok, view, html} = live(conn, ~p"/triage")

    assert has_element?(view, "#triage-filter-waiting", "Waiting · 1")
    assert has_element?(view, "#triage-channels", "#rail-feedback")
    assert has_element?(view, "#triage-row-#{thread_id}", "Tasks stuck at Design")
    assert has_element?(view, "#triage-row-#{thread_id}", "4 to accept")
    assert has_element?(view, "#triage-badge", "1")

    assert has_element?(view, "#triage-source", "#rail-feedback · Priya Natarajan")
    assert has_element?(view, "#triage-thread-title", "Tasks stuck at Design, wait times in Up next")
    assert has_element?(view, "#triage-reply", "Thanks Priya, we reproduced the first and filed both.")
    assert has_element?(view, "#triage-reply-form", "Reply in Slack as Michael")
    assert has_element?(view, "#triage-reply-form", "Draft, not sent")
    assert has_element?(view, "#triage-tickets-line", "Tickets · 2 to create · 1 follow-up")

    assert has_element?(view, "#triage-ticket-title-#{bug.id}[value='Approve leaves tasks at Design']")
    assert has_element?(view, "#triage-ticket-verdict-#{bug.id}", "Confirmed")
    assert has_element?(view, "#triage-ticket-kind-#{bug.id} option[value='bug'][selected]")
    assert has_element?(view, "#triage-ticket-priority-#{bug.id} option[value='high'][selected]")
    assert has_element?(view, "#triage-ticket-estimate-#{bug.id} option[value=''][selected]", "No estimate")
    assert has_element?(view, "#triage-ticket-estimate-#{request.id} option[value='2'][selected]", "2 points")
    assert has_element?(view, "#triage-ticket-verdict-#{request.id}", "Partly built")
    assert has_element?(view, "#triage-ticket-#{covered.id}", "Follow up on #{existing.identifier}")
    assert has_element?(view, "#triage-ticket-tracked-#{covered.id}[href='/issues/#{existing.id}']")
    assert has_element?(view, "#triage-ticket-followup-#{covered.id}", "Priya hit it too, on BILL-88.")
    refute has_element?(view, "#triage-ticket-title-#{covered.id}")

    refute html =~ "Rows show no wait."
    refute html =~ "lib/enter_stage.ex"
    refute html =~ "Billing is the BILL project."

    assert has_element?(view, "#triage-send-button", "Send reply, create 2 tickets & update 1")
    refute has_element?(view, "#triage-send-button[disabled]")

    assert has_element?(
             view,
             "#triage-send-hint",
             "Comments on #{existing.identifier} and creates 2 tickets in #{project.key}, then posts in #rail-feedback as you."
           )

    assert has_element?(view, "#triage-chat [data-qa='triage-chat-line']", "Three items. One is already tracked.")
    assert has_element?(view, "#triage-chat", "Added item 1 · Added item 2 · Added item 3")
    assert has_element?(view, "#triage-panel-thread", "Thread · 1")
    refute has_element?(view, "#triage-thread")
    refute html =~ "Triage again"
    refute html =~ "Triage anyway"

    view |> element("#triage-panel-thread") |> render_click()
    assert has_element?(view, "#triage-thread mark", "Approved BILL-88 and it sits at Design.")
    assert has_element?(view, "#triage-thread", "Priya Natarajan")
    assert has_element?(view, "#open-in-slack", "Open in Slack")
    refute has_element?(view, "#triage-chat")

    view |> element("#triage-panel-chat") |> render_click()
    assert has_element?(view, "#triage-chat")
  end

  test "the reply promises the new tickets' links, except in a channel people outside the team read", %{
    conn: conn,
    channel: %{id: channel_id},
    thread: %Thread{id: thread_id}
  } do
    {:ok, view, _html} = live(conn, ~p"/triage/#{thread_id}")
    assert has_element?(view, "#triage-reply-links", "Rail adds the new tickets' links when it posts.")

    Repo.update_all(from(c in SlackChannel, where: c.id == ^channel_id), set: [external: true])
    Phoenix.PubSub.broadcast(Rail.PubSub, "triage", {:triage_changed, thread_id})
    assert has_element?(view, "#triage-reply-form")
    refute has_element?(view, "#triage-reply-links")
  end

  test "the reply and a card's fields save as typed, survive a reload, and a changed kind hides its verdict", %{
    conn: conn,
    thread: %Thread{id: thread_id, items: [bug, _request, _covered]}
  } do
    {:ok, view, _html} = live(conn, ~p"/triage")

    view
    |> form("#triage-reply-form", %{"thread" => %{"reply_text" => "Thanks Priya.\r\n\r\nFiled."}})
    |> render_change()

    view
    |> form("#triage-ticket-form-#{bug.id}", %{
      "item" => %{
        "kind" => "feature_request",
        "issue_title" => "Approving moves the task on",
        "issue_description" => "Rewritten.",
        "issue_priority" => "low",
        "issue_estimate" => "3"
      }
    })
    |> render_change()

    assert %Thread{reply_text: "Thanks Priya.\n\nFiled."} = Repo.get!(Thread, thread_id)

    assert %Item{kind: :feature_request, issue_title: "Approving moves the task on", issue_estimate: 3} =
             Repo.get!(Item, bug.id)

    refute has_element?(view, "#triage-ticket-verdict-#{bug.id}")

    {:ok, fresh, _html} = live(conn, ~p"/triage/#{thread_id}")
    assert has_element?(fresh, "#triage-reply", "Filed.")
    assert has_element?(fresh, "#triage-ticket-title-#{bug.id}[value='Approving moves the task on']")
    assert has_element?(fresh, "#triage-ticket-description-#{bug.id}", "Rewritten.")
    assert has_element?(fresh, "#triage-ticket-priority-#{bug.id} option[value='low'][selected]")

    render_change(view, "update_item", %{"item_id" => bug.id, "item" => %{"issue_estimate" => "4"}})
    assert has_element?(view, "#triage-refused", "That did not save.")
  end

  test "clearing the reply keeps its box to write a new one, and a thread drafted with no reply has one", %{
    conn: conn,
    workspace: workspace,
    channel: channel,
    thread: %Thread{id: thread_id}
  } do
    {:ok, view, _html} = live(conn, ~p"/triage/#{thread_id}")

    view |> form("#triage-reply-form", %{"thread" => %{"reply_text" => ""}}) |> render_change()
    assert has_element?(view, "#triage-reply-form")
    refute has_element?(view, "#triage-send-button", "Send reply")

    view |> form("#triage-reply-form", %{"thread" => %{"reply_text" => "Both filed, thanks."}}) |> render_change()
    assert has_element?(view, "#triage-send-button", "Send reply")

    {:ok, quiet} =
      Triage.handle_slack_event(workspace, slack_message_event(channel, %{"ts" => "1790000600.000400"}))

    triage_with(quiet, triage_result([triage_bug()], %{"reply" => nil}))
    {:ok, other, _html} = live(conn, ~p"/triage/#{quiet.id}")
    assert has_element?(other, "#triage-reply-form")
    assert has_element?(other, "#triage-send-button", "Create 1 ticket")
  end

  test "Ignore greys a card, keeps it, and takes it out of the button; switching it off counts it again", %{
    conn: conn,
    thread: %Thread{items: [_bug, request, covered]}
  } do
    {:ok, view, _html} = live(conn, ~p"/triage")

    view |> element("#triage-ticket-ignore-#{covered.id}") |> render_click()

    assert has_element?(view, "#triage-ticket-#{covered.id}[data-ignored='true'].opacity-55")
    assert has_element?(view, "#triage-ticket-ignore-#{covered.id}[role='switch'][aria-checked='true']")
    assert has_element?(view, "#triage-ticket-ignored-#{covered.id}", "Ignored · not added")
    assert has_element?(view, "#triage-send-button", "Send reply & create 2 tickets")
    assert has_element?(view, "#triage-tickets-line", "Tickets · 2 to create · 1 ignored")

    view |> element("#triage-ticket-ignore-#{request.id}") |> render_click()
    assert has_element?(view, "#triage-ticket-ignored-#{request.id}", "Ignored · not created")
    assert has_element?(view, "#triage-send-button", "Send reply & create 1 ticket")

    view |> element("#triage-ticket-ignore-#{covered.id}") |> render_click()
    assert has_element?(view, "#triage-ticket-ignore-#{covered.id}[aria-checked='false']")
    assert has_element?(view, "#triage-send-button", "Send reply, create 1 ticket & update 1")
  end

  test "a chat line runs the agent, which locks the page on every tab, and its answer shows without a reload", %{
    conn: conn,
    thread: %Thread{id: thread_id, items: [bug, request, covered]} = thread
  } do
    {:ok, view, _html} = live(conn, ~p"/triage/#{thread_id}")
    {:ok, other_tab, _html} = live(conn, ~p"/triage/#{thread_id}")

    view |> form("#triage-chat-form", %{"chat_message" => %{"text" => "Make the"}}) |> render_change()
    assert has_element?(view, "#triage-chat-text", "Make the")

    view |> form("#triage-chat-form", %{"chat_message" => %{"text" => "  "}}) |> render_submit()
    assert [] = Repo.all(from c in ChatMessage, where: c.thread_id == ^thread_id and c.author == :person)

    view |> form("#triage-chat-form", %{"chat_message" => %{"text" => "Make the reply shorter."}}) |> render_submit()

    assert has_element?(view, "[data-qa='triage-chat-line']", "Make the reply shorter.")
    refute has_element?(view, "#triage-chat-text", "Make the")

    for tab <- [view, other_tab] do
      assert has_element?(tab, "#triage-running", "Running")
      assert has_element?(tab, "#triage-chat-running", "Running")
      assert has_element?(tab, "#triage-reply[readonly]")
      assert has_element?(tab, "#triage-ticket-title-#{bug.id}[readonly]")
      refute has_element?(tab, "#triage-ticket-kind-#{bug.id}")
      assert has_element?(tab, "#triage-ticket-ignore-#{request.id}[disabled]")
      assert has_element?(tab, "#triage-send-button[disabled]")
      assert has_element?(tab, "#triage-chat-text[disabled]")
      assert has_element?(tab, "#triage-send-hint", "Send waits until the agent finishes.")
    end

    # A reconnect sends the disabled chat box back with no text.
    render_change(view, "chat_change", %{"_target" => ["chat_message", "text"]})
    assert has_element?(view, "#triage-chat-running", "Running")

    render_click(view, "toggle_ignore", %{"item_id" => covered.id})
    assert has_element?(view, "#triage-refused", "The agent is still working on this thread.")
    assert %Item{ignored: false} = Repo.get!(Item, covered.id)

    restated = [
      Map.put(triage_bug(), "issue", %{"title" => "Approving moves a task on", "priority" => "high"}),
      %{
        "key" => request.key,
        "kind" => "feature_request",
        "title" => request.title,
        "verdict" => "partly_built",
        "issue" => %{"title" => request.issue_title, "priority" => "low", "estimate" => 2}
      },
      %{
        "key" => covered.key,
        "kind" => "bug",
        "title" => covered.title,
        "verdict" => "confirmed",
        "existing_issue" => Repo.get!(Issue, covered.existing_issue_id).identifier,
        "followup" => covered.followup_text
      }
    ]

    message = %{"message" => "Cut it to one line and retitled item 1.", "reply" => "Reproduced and filed, thanks."}
    triage_with(Repo.get!(Thread, thread.id), triage_result(restated, message))

    for tab <- [view, other_tab] do
      assert has_element?(tab, "#triage-reply", "Reproduced and filed, thanks.")
      assert has_element?(tab, "#triage-ticket-title-#{bug.id}[value='Approving moves a task on']")
      assert has_element?(tab, "[data-qa='triage-chat-line']", "Cut it to one line and retitled item 1.")
      assert has_element?(tab, "[data-qa='triage-chat-line']", "Edited the reply · Edited item 1")
      refute has_element?(tab, "#triage-running")
      refute has_element?(tab, "#triage-send-button[disabled]")
    end
  end

  test "Send comments, creates and posts as the person, and the Done thread keeps all of it on screen", %{
    conn: conn,
    user: %{id: user_id},
    existing: %{id: existing_id, identifier: tracked},
    thread: %Thread{id: thread_id, items: [bug, request, covered]}
  } do
    {:ok, view, _html} = live(conn, ~p"/triage")
    Req.Test.allow(Rail.Slack, self(), view.pid)

    Req.Test.expect(Rail.Slack, fn conn ->
      assert %{"text" => "Thanks Priya, we reproduced the first and filed both.\n\nFiled as " <> _links} =
               conn |> Req.Test.raw_body() |> Jason.decode!()

      Req.Test.json(conn, %{"ok" => true, "ts" => "1790000500.000100"})
    end)

    view |> element("#triage-send-button") |> render_click()

    assert %Thread{status: :done, reply_posted_by_id: ^user_id} = Repo.get!(Thread, thread_id)
    assert [%Comment{}] = Repo.all(from c in Comment, where: c.issue_id == ^existing_id)
    %Item{created_issue_id: issue_id} = Repo.get!(Item, bug.id)

    assert has_element?(view, "#triage-reply-posted", "Posted by Michael at")
    assert has_element?(view, "#triage-reply[readonly]", "Filed as")
    assert has_element?(view, "#triage-sent", "Sent by Michael at")
    assert has_element?(view, "#triage-sent", "2 tickets created, 1 follow-up added.")
    assert has_element?(view, "#triage-ticket-created-#{bug.id}", "Created")
    assert has_element?(view, "#triage-ticket-issue-#{bug.id}[href='/issues/#{issue_id}']")
    assert has_element?(view, "#triage-ticket-start-#{bug.id}[href='/issues/#{issue_id}']", "Start")
    assert has_element?(view, "#triage-ticket-created-#{request.id}")
    assert has_element?(view, "#triage-ticket-commented-#{covered.id}", "Comment added to #{tracked}")
    assert has_element?(view, "#triage-ticket-title-#{bug.id}[readonly]")
    refute has_element?(view, "#triage-ticket-ignore-#{bug.id}")
    refute has_element?(view, "#triage-send-button")
    refute has_element?(view, "#dismiss-thread-button")
    assert has_element?(view, "[data-qa='triage-chat-line']", "Three items. One is already tracked.")

    view |> element("#triage-filter-done") |> render_click()
    assert has_element?(view, "#triage-row-#{thread_id}", "Accepted by Michael")
  end

  test "a created ticket shows its task's stage once started, or its state once closed", %{
    conn: conn,
    thread: %Thread{id: thread_id, items: [bug, _request, _covered]} = thread,
    user: user
  } do
    {:ok, _cleared} = Triage.update_triage_reply(Rail.Scope.for_user(user), thread, %{"reply_text" => ""})
    {:ok, _sent} = Triage.send_triage_reply(Rail.Scope.for_user(user), thread)
    %Item{created_issue_id: issue_id} = Repo.get!(Item, bug.id)

    {:ok, view, _html} = live(conn, ~p"/triage/#{thread_id}")
    assert has_element?(view, "#triage-sent", "Sent: 2 tickets created, 1 follow-up added.")
    # The round's tickets are out, so a reply typed now goes without links.
    assert has_element?(view, "#triage-reply-form")
    refute has_element?(view, "#triage-reply-links")

    {:ok, %Task{id: task_id}} = Pipeline.create_task(Repo.preload(Repo.get!(Issue, issue_id), :project), :plan)
    Phoenix.PubSub.broadcast(Rail.PubSub, "pipeline", {:pipeline_changed, task_id})
    assert has_element?(view, "#triage-ticket-task-#{bug.id}[href='/tasks/#{task_id}']", "Plan")
    refute has_element?(view, "#triage-ticket-start-#{bug.id}")

    %Item{created_issue_id: other_id} = Repo.get!(Item, Enum.at(thread.items, 1).id)
    Repo.update_all(from(i in Issue, where: i.id == ^other_id), set: [state: :canceled])
    Phoenix.PubSub.broadcast(Rail.PubSub, "triage", {:triage_changed, thread_id})
    assert has_element?(view, "#triage-ticket-issue-state-#{Enum.at(thread.items, 1).id}", "Canceled")
  end

  test "a Send that stops partway says so on every tab, and Send again does only what is left", %{
    conn: conn,
    existing: %{id: existing_id},
    thread: %Thread{id: thread_id, items: [bug, request, covered]}
  } do
    {:ok, view, _html} = live(conn, ~p"/triage/#{thread_id}")
    {:ok, other_tab, _html} = live(conn, ~p"/triage/#{thread_id}")
    allow(Issues, self(), view.pid)
    Req.Test.allow(Rail.Slack, self(), view.pid)

    expect(Issues, :create_issue, 2, fn scope, project, attrs ->
      if attrs.title == "Every Up next row shows its wait",
        do: {:error, :db_down},
        else: call_original(Issues, :create_issue, [scope, project, attrs])
    end)

    view |> element("#triage-send-button") |> render_click()

    for tab <- [view, other_tab] do
      assert has_element?(tab, "#triage-send-error", "Send stopped partway. Could not create item 2")
      assert has_element?(tab, "#triage-ticket-created-#{bug.id}")
      assert has_element?(tab, "#triage-send-button", "Send reply & create 1 ticket")
      assert has_element?(tab, "#triage-ticket-commented-#{covered.id}", "Comment added to")
    end

    refute has_element?(view, "#triage-refused")

    expect(Issues, :create_issue, fn scope, project, attrs ->
      call_original(Issues, :create_issue, [scope, project, attrs])
    end)

    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "ts" => "1790000500.000200"}))
    view |> element("#triage-send-button") |> render_click()

    assert has_element?(other_tab, "#triage-ticket-created-#{request.id}")
    refute has_element?(other_tab, "#triage-send-error")
    assert 1 = Repo.aggregate(from(c in Comment, where: c.issue_id == ^existing_id), :count)
  end

  test "a Send another tab holds, one Slack refuses, or a follow-up the tracker refuses, is said on the page", %{
    conn: conn,
    thread: %Thread{id: thread_id}
  } do
    {:ok, view, _html} = live(conn, ~p"/triage/#{thread_id}")
    Req.Test.allow(Rail.Slack, self(), view.pid)
    allow(Issues, self(), view.pid)

    stub(Issues, :comment, fn scope, issue, attrs -> call_original(Issues, :comment, [scope, issue, attrs]) end)
    expect(Issues, :comment, fn _scope, _issue, _attrs -> {:error, :db_down} end)
    view |> element("#triage-send-button") |> render_click()
    assert has_element?(view, "#triage-send-error", "Could not add the follow-up on item 3")

    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [send_started_at: DateTime.utc_now()])
    view |> element("#triage-send-button") |> render_click()
    assert has_element?(view, "#triage-refused", "This thread is being sent.")

    view |> form("#triage-chat-form", %{"chat_message" => %{"text" => "Shorter."}}) |> render_submit()
    assert has_element?(view, "#triage-refused", "This thread is being sent.")

    send(view.pid, {:triage_changed, thread_id})
    assert has_element?(view, "#triage-refused", "This thread is being sent.")

    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [send_started_at: nil])
    send(view.pid, {:triage_changed, thread_id})
    refute has_element?(view, "#triage-refused")

    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "not_in_channel"}))
    view |> element("#triage-send-button") |> render_click()

    refute has_element?(view, "#triage-refused")
    assert has_element?(view, "#triage-send-error", "Slack did not take the reply.")
    # Every ticket is made, and Send again still ends the reply with their links.
    assert has_element?(view, "#triage-reply-links")
  end

  test "a sent thread names who posted it, by login without a name, and as someone once they are gone", %{
    conn: conn,
    thread: %Thread{id: thread_id}
  } do
    unique = System.unique_integer([:positive])

    {:ok, poster} =
      Users.register_oauth_user(%{github_id: "po_#{unique}", login: "po_#{unique}", email: "po_#{unique}@x.com"})

    now = DateTime.utc_now()

    Repo.update_all(from(t in Thread, where: t.id == ^thread_id),
      set: [reply_posted_at: now, reply_posted_by_id: poster.id, status: :done]
    )

    Repo.update_all(from(i in Item, where: i.thread_id == ^thread_id), set: [sent_at: now])

    {:ok, view, _html} = live(conn, ~p"/triage/#{thread_id}?filter=done")
    assert has_element?(view, "#triage-reply-posted", "Posted by po_#{unique} at")
    assert has_element?(view, "#triage-sent", "Sent by po_#{unique} at")

    Repo.delete!(poster)
    {:ok, view, _html} = live(conn, ~p"/triage/#{thread_id}?filter=done")
    assert has_element?(view, "#triage-reply-posted", "Posted by someone at")
    assert has_element?(view, "#triage-sent", "Sent by someone at")
  end

  test "a thread that only needed a reply says who sent it once it is posted", %{
    conn: conn,
    workspace: workspace,
    channel: channel
  } do
    {:ok, thread} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{"ts" => "1790000600.000500", "text" => "How do I re-run a stage?"})
      )

    triage_with(thread, triage_result([], %{"reply" => "Open the task and press Retry."}))
    {:ok, view, _html} = live(conn, ~p"/triage/#{thread.id}")
    assert has_element?(view, "#triage-reply-form")
    refute has_element?(view, "#triage-reply-links")
    Req.Test.allow(Rail.Slack, self(), view.pid)
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "ts" => "1790000600.000600"}))

    view |> element("#triage-send-button", "Send reply") |> render_click()

    assert has_element?(view, "#triage-sent", "Sent by Michael at")
    assert has_element?(view, "#triage-sent", "A new message in the thread brings it back.")
    refute has_element?(view, "#triage-send-hint")
  end

  test "a person who has not linked Slack is told how to, and cannot send the reply", %{
    conn: conn,
    project: project,
    thread: %Thread{id: thread_id}
  } do
    unique = System.unique_integer([:positive])

    {:ok, unlinked} =
      Users.register_oauth_user(%{github_id: "ul_#{unique}", login: "ul_#{unique}", email: "ul_#{unique}@x.com"})

    {:ok, unlinked} = Users.update_user(system_scope(), unlinked, %{project_ids: [project.id]})
    {:ok, view, _html} = live(log_in_user(conn, unlinked), ~p"/triage/#{thread_id}")

    assert has_element?(view, "#triage-link-prompt", "Connect Slack to post as yourself.")
    assert has_element?(view, "#connect-slack[href='/settings/connected-accounts']")
    assert has_element?(view, "#triage-send-button[disabled]")
    assert has_element?(view, "#triage-reply-form", "Reply in Slack as ul_#{unique}")
  end

  test "a failed pass shows why, and the chat is how to try again", %{
    conn: conn,
    thread: %Thread{id: thread_id}
  } do
    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [error: "This project has no Triage role."])

    {:ok, view, html} = live(conn, ~p"/triage/#{thread_id}")
    assert has_element?(view, "#triage-error", "Triage did not finish. This project has no Triage role.")
    assert has_element?(view, "#triage-error", "Tell the agent in the chat to try again.")
    refute html =~ "Triage again"

    view |> form("#triage-chat-form", %{"chat_message" => %{"text" => "Try again."}}) |> render_submit()
    assert %Thread{error: nil, status: :triaging} = Repo.get!(Thread, thread_id)
    refute has_element?(view, "#triage-error")
  end

  test "a thread that needed no response says to ask in the chat, and nothing is drafted", %{
    conn: conn,
    workspace: workspace,
    channel: channel
  } do
    {:ok, thread} =
      Triage.handle_slack_event(workspace, slack_message_event(channel, %{"ts" => "1790000600.000100", "text" => "ty"}))

    triage_with(
      thread,
      triage_result([], %{
        "reply" => nil,
        "messages" => [%{"ts" => thread.external_id, "needs_response" => false, "reason" => "a thank-you"}]
      })
    )

    {:ok, view, html} = live(conn, ~p"/triage/#{thread.id}?filter=done")

    assert has_element?(
             view,
             "#triage-no-response",
             "Rail read this as: a thank-you. If it needs a response, say so in the chat."
           )

    refute has_element?(view, "#triage-reply-form")
    assert has_element?(view, "#triage-send-hint", "Nothing to send yet.")
    refute has_element?(view, "#triage-send-button")
    refute html =~ "Triage anyway"

    view |> element("#triage-panel-thread") |> render_click()
    assert has_element?(view, "#triage-thread", "Needs no response. Nothing drafted.")
  end

  test "a thread with nothing drafted yet says so", %{conn: conn, workspace: workspace, channel: channel} do
    {:ok, thread} = Triage.handle_slack_event(workspace, slack_message_event(channel, %{"ts" => "1790000600.000300"}))
    Repo.update_all(from(t in Thread, where: t.id == ^thread.id), set: [status: :waiting, error: "Timed out."])

    {:ok, view, _html} = live(conn, ~p"/triage/#{thread.id}")
    assert has_element?(view, "#triage-nothing", "Nothing is drafted yet.")
    assert has_element?(view, "#triage-chat-empty", "Ask it to change the reply or the tickets")
  end

  test "dismissing a thread finishes it and locks it until a chat line brings it back", %{
    conn: conn,
    thread: %Thread{id: thread_id, items: [bug, _request, _covered]}
  } do
    {:ok, view, _html} = live(conn, ~p"/triage/#{thread_id}")
    view |> element("#dismiss-thread-button") |> render_click()

    assert %Thread{status: :done, dismissed_at: %DateTime{}} = Repo.get!(Thread, thread_id)
    assert has_element?(view, "#triage-reply[readonly]")
    assert has_element?(view, "#triage-reply-form")
    refute has_element?(view, "#triage-reply-links")
    assert has_element?(view, "#triage-ticket-ignore-#{bug.id}[disabled]")
    refute has_element?(view, "#triage-send-button")

    view |> form("#triage-reply-form", %{"thread" => %{"reply_text" => "Changed"}}) |> render_change()
    assert has_element?(view, "#triage-refused", "This thread was dismissed. Write in the chat to bring it back.")

    view |> form("#triage-chat-form", %{"chat_message" => %{"text" => "Actually, look again."}}) |> render_submit()
    assert %Thread{status: :triaging, dismissed_at: nil} = Repo.get!(Thread, thread_id)
  end

  test "an edit to a card a pass just removed is let go, and the card is gone", %{
    conn: conn,
    thread: %Thread{id: thread_id}
  } do
    {:ok, view, _html} = live(conn, ~p"/triage/#{thread_id}")
    render_click(view, "toggle_ignore", %{"item_id" => "tit_gone"})
    refute has_element?(view, "#triage-refused")
  end

  test "a bot's post shows its name and APP", %{conn: conn, project: project} do
    %{workspace: workspace, channel: channel} = connect_slack_channel(project, bot_triage_enabled: true)

    {:ok, thread} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{"bot_id" => "B_PH", "username" => "PostHog", "text" => "TypeError"})
      )

    {:ok, view, _html} = live(conn, ~p"/triage/#{thread.id}?filter=triaging")
    view |> element("#triage-panel-thread") |> render_click()

    assert has_element?(view, "#triage-thread [data-qa='triage-message']", "PostHog")
    assert has_element?(view, "#triage-thread [data-qa='triage-message']", "APP")

    triage_with(thread, triage_result([triage_bug()], %{"reply" => nil}))
    send(view.pid, {:triage_changed, thread.id})
    view |> element("#triage-filter-waiting") |> render_click()
    assert has_element?(view, "#triage-row-#{thread.id}", "Confirmed")
  end

  test "an announced change re-renders the page", %{conn: conn, thread: %Thread{id: thread_id}} do
    {:ok, view, _html} = live(conn, ~p"/triage")

    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [title: "Renamed elsewhere"])
    send(view.pid, {:triage_changed, thread_id})
    send(view.pid, {:issue_created, "iss_any"})
    send(view.pid, {:project_changed, "prj_any"})

    assert has_element?(view, "#triage-thread-title", "Renamed elsewhere")
  end

  test "a project the user cannot access is left out of the queue, the counts and a link to its thread, as is an unknown thread",
       %{
         conn: conn,
         thread: %Thread{id: thread_id}
       } do
    %{project: hidden_project} = triage_project()
    %{workspace: workspace, channel: channel} = connect_slack_channel(hidden_project)

    {:ok, hidden} =
      Triage.handle_slack_event(workspace, slack_message_event(channel, %{"text" => "A secret request"}))

    %Thread{id: hidden_id} = triage_with(hidden, %{"title" => "Hidden thread", "items" => [triage_bug()]})

    {:ok, view, _html} = live(conn, ~p"/triage")

    assert has_element?(view, "#triage-row-#{thread_id}")
    refute has_element?(view, "#triage-row-#{hidden_id}")
    assert has_element?(view, "#triage-filter-waiting", "Waiting · 1")
    assert has_element?(view, "#triage-badge", "1")

    {:ok, view, html} = live(conn, ~p"/triage/#{hidden_id}")

    refute has_element?(view, "#triage-draft-column-#{hidden_id}")
    refute html =~ "A secret request"
    refute render(view) =~ "Hidden thread"

    {:ok, view, _html} = live(conn, ~p"/triage/tth_missing?filter=bogus")
    refute has_element?(view, "[id^='triage-draft-column-']")
  end

  describe "images a message came with" do
    setup %{workspace: workspace, channel: channel, thread: thread} do
      {:ok, _thread} =
        Triage.handle_slack_event(
          workspace,
          slack_message_event(channel, %{
            "subtype" => "file_share",
            "ts" => "1790000100.000200",
            "thread_ts" => thread.external_id,
            "text" => "Here is what I see",
            "files" => [
              %{
                "id" => "F_ONE",
                "name" => "one.png",
                "mimetype" => "image/png",
                "url_private" => "https://files.slack.com/files-pri/T1-F_ONE/one.png"
              },
              %{"id" => "F_HIDDEN", "file_access" => "check_file_info"},
              %{
                "id" => "F_TWO",
                "name" => "two.png",
                "mimetype" => "image/png",
                "url_private" => "https://files.slack.com/files-pri/T1-F_TWO/two.png"
              },
              %{
                "id" => "F_THREE",
                "name" => "three.png",
                "mimetype" => "image/png",
                "url_private" => "https://files.slack.com/files-pri/T1-F_THREE/three.png"
              },
              %{"id" => "F_DOC", "name" => "notes.pdf", "mimetype" => "application/pdf"}
            ]
          })
        )

      {:ok, _thread} =
        Triage.handle_slack_event(
          workspace,
          slack_message_event(channel, %{
            "subtype" => "file_share",
            "ts" => "1790000200.000300",
            "thread_ts" => thread.external_id,
            "text" => "One more",
            "files" => [
              %{
                "id" => "F_FOUR",
                "name" => "four.png",
                "mimetype" => "image/png",
                "url_private" => "https://files.slack.com/files-pri/T1-F_FOUR/four.png"
              }
            ]
          })
        )

      {:ok, %Thread{messages: [first, shots, single]}} = Triage.get_triage_thread(system_scope(), thread.id)

      %{first: first, shots: shots, single: single}
    end

    test "each message shows its own images as tiles under its text, in Slack's order", %{
      conn: conn,
      thread: thread,
      first: first,
      shots: shots,
      single: single
    } do
      {:ok, view, _html} = live(conn, ~p"/triage/#{thread.id}")
      view |> element("#triage-panel-thread") |> render_click()

      tiles =
        view
        |> element("#triage-message-#{shots.id} #triage-images-#{shots.id}")
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.find("[data-qa^='triage-image']:not([data-qa*='-loading']):not([data-qa*='-failed'])")
        |> Enum.map(&(&1 |> Floki.attribute("id") |> List.first()))

      assert tiles == [
               "triage-image-#{shots.id}-F_ONE",
               "triage-image-#{shots.id}-F_HIDDEN",
               "triage-image-#{shots.id}-F_TWO",
               "triage-image-#{shots.id}-F_THREE"
             ]

      assert has_element?(view, "#triage-image-#{shots.id}-F_ONE", "one.png")
      assert has_element?(view, "#triage-image-#{shots.id}-F_THREE", "three.png")
      refute has_element?(view, "#triage-thread", "notes.pdf")
      assert has_element?(view, "#triage-message-#{single.id} #triage-image-#{single.id}-F_FOUR")
      refute has_element?(view, "#triage-images-#{first.id}")
      refute has_element?(view, "#triage-message-#{first.id} [data-qa='triage-image']")
    end

    test "a tile is a button labeled for its image, loaded from Rail, pulsing until the browser marks it", %{
      conn: conn,
      thread: thread,
      shots: shots
    } do
      {:ok, view, _html} = live(conn, ~p"/triage/#{thread.id}")
      view |> element("#triage-panel-thread") |> render_click()
      tile = "#triage-image-#{shots.id}-F_TWO"

      assert has_element?(view, "#{tile}[phx-hook='ImageFallback'][data-image='loading']")

      assert has_element?(
               view,
               "#{tile} button#triage-image-open-#{shots.id}-F_TWO[aria-label='Enlarge two.png'][phx-click='open_image']"
             )

      assert has_element?(view, ~s(#{tile} img[src="/triage/messages/#{shots.id}/images/F_TWO"][loading="lazy"]))
      assert has_element?(view, "#{tile} [data-qa='triage-image-loading'].motion-safe\\:animate-pulse")

      assert has_element?(
               view,
               "#{tile} [data-qa='triage-image-failed'][title='Rail could not load two.png.']",
               "Rail could not load it."
             )

      assert has_element?(view, "#{tile} [data-qa='triage-image-failed']", "two.png")
      refute has_element?(view, "#{tile} [data-qa='triage-image-failed'][phx-click]")
    end

    test "a file Slack withheld is an unnamed placeholder that opens nothing", %{
      conn: conn,
      thread: thread,
      shots: shots
    } do
      {:ok, view, _html} = live(conn, ~p"/triage/#{thread.id}")
      view |> element("#triage-panel-thread") |> render_click()
      withheld = "#triage-image-#{shots.id}-F_HIDDEN"

      assert has_element?(view, withheld, "A file was attached that Rail cannot see.")
      refute has_element?(view, "#{withheld} img")
      refute has_element?(view, "#{withheld} button")
      refute has_element?(view, "#{withheld}[phx-click]")
      refute has_element?(view, "[aria-label='Enlarge ']")

      render_hook(view, "open_image", %{"message_id" => shots.id, "file_id" => "F_HIDDEN"})
      refute has_element?(view, "#triage-image-view")

      render_hook(view, "open_image", %{"message_id" => shots.id, "file_id" => "F_DOC"})
      refute has_element?(view, "#triage-image-view")
    end

    test "a tile opens the image in a dialog over the page, loading from Rail, and it closes", %{
      conn: conn,
      thread: thread,
      shots: shots
    } do
      {:ok, view, _html} = live(conn, ~p"/triage/#{thread.id}")
      view |> element("#triage-panel-thread") |> render_click()

      view |> element("#triage-image-open-#{shots.id}-F_ONE") |> render_click()

      assert has_element?(view, "#triage-image-panel[role='dialog'][aria-modal='true'][aria-label='one.png']")
      assert has_element?(view, "#triage-image-name", "one.png")
      assert has_element?(view, "#triage-image-close[aria-label='Close']")

      assert has_element?(
               view,
               ~s(a#triage-image-original[href="/triage/messages/#{shots.id}/images/F_ONE"][target="_blank"]),
               "Open original"
             )

      assert has_element?(view, "#triage-image-original.group-has-\\[\\[data-image\\=failed\\]\\]\\/panel\\:hidden")
      assert has_element?(view, "#triage-thread")
      assert has_element?(view, "#triage-draft-column-#{thread.id}")

      picture = "#triage-image-picture-F_ONE[phx-hook='ImageFallback'][data-image='loading']"
      assert has_element?(view, picture)
      refute has_element?(view, "#triage-image-picture-F_ONE[style]")
      assert has_element?(view, "#{picture} [data-qa='triage-image-view-loading'].motion-safe\\:animate-pulse")
      assert has_element?(view, "#{picture} [data-qa='triage-image-view-failed']", "Rail could not load one.png.")

      assert view |> element("#{picture} img") |> render() =~
               "hidden group-data-[image=loaded]/picture:block max-w-none h-auto w-[min(calc(var(--natural-width)*2px),100cqw,calc(100cqh*var(--natural-width)/var(--natural-height)))]"

      assert view |> element("#triage-image-panel") |> render() =~ ~s(phx-click-away=)

      view |> element("#triage-image-close") |> render_click()
      refute has_element?(view, "#triage-image-view")

      view |> element("#triage-image-open-#{shots.id}-F_ONE") |> render_click()
      view |> element("#triage-image-view") |> render_keydown(%{"key" => "Escape"})
      refute has_element?(view, "#triage-image-view")
    end

    test "Previous, Next and the arrow keys step through this message's images only, stopping at the ends", %{
      conn: conn,
      thread: thread,
      shots: shots
    } do
      {:ok, view, _html} = live(conn, ~p"/triage/#{thread.id}")
      view |> element("#triage-panel-thread") |> render_click()
      view |> element("#triage-image-open-#{shots.id}-F_ONE") |> render_click()

      panel_class =
        view |> element("#triage-image-panel") |> render() |> Floki.parse_fragment!() |> Floki.attribute("class")

      assert has_element?(view, "#triage-image-position[aria-live='polite']", "1 of 3")
      assert has_element?(view, "#triage-image-previous[aria-disabled='true']")
      assert has_element?(view, "#triage-image-next[aria-disabled='false']")
      assert has_element?(view, "#triage-image-divider")

      view |> element("#triage-image-previous") |> render_click()
      assert has_element?(view, "#triage-image-position", "1 of 3")
      assert has_element?(view, "#triage-image-name", "one.png")

      view |> element("#triage-image-next") |> render_click()
      assert has_element?(view, "#triage-image-position", "2 of 3")
      assert has_element?(view, "#triage-image-name", "two.png")
      assert has_element?(view, "#triage-image-picture-F_TWO[data-image='loading']")
      refute has_element?(view, "#triage-image-picture-F_ONE")

      view |> element("#triage-image-panel") |> render_keydown(%{"key" => "ArrowRight"})
      assert has_element?(view, "#triage-image-position", "3 of 3")
      assert has_element?(view, "#triage-image-name", "three.png")
      assert has_element?(view, "#triage-image-next[aria-disabled='true']")

      view |> element("#triage-image-next") |> render_click()
      view |> element("#triage-image-panel") |> render_keydown(%{"key" => "ArrowRight"})
      assert has_element?(view, "#triage-image-position", "3 of 3")
      refute has_element?(view, "#triage-image-name", "four.png")

      view |> element("#triage-image-panel") |> render_keydown(%{"key" => "a"})
      assert has_element?(view, "#triage-image-position", "3 of 3")

      assert view |> element("#triage-image-panel") |> render() |> Floki.parse_fragment!() |> Floki.attribute("class") ==
               panel_class

      view |> element("#triage-image-panel") |> render_keydown(%{"key" => "ArrowLeft"})
      assert has_element?(view, "#triage-image-position", "2 of 3")
      view |> element("#triage-image-previous") |> render_click()
      assert has_element?(view, "#triage-image-position", "1 of 3")
      view |> element("#triage-image-panel") |> render_keydown(%{"key" => "ArrowLeft"})
      assert has_element?(view, "#triage-image-position", "1 of 3")
    end

    test "after stepping, every way of closing returns focus to the tile of the image on screen", %{
      conn: conn,
      thread: thread,
      shots: shots
    } do
      {:ok, view, _html} = live(conn, ~p"/triage/#{thread.id}")
      view |> element("#triage-panel-thread") |> render_click()
      view |> element("#triage-image-open-#{shots.id}-F_ONE") |> render_click()
      view |> element("#triage-image-next") |> render_click()
      view |> element("#triage-image-next") |> render_click()

      focus = "#triage-image-open-#{shots.id}-F_THREE"

      for {selector, attribute} <- [
            {"#triage-image-close", "phx-click"},
            {"#triage-image-view", "phx-window-keydown"},
            {"#triage-image-panel", "phx-click-away"}
          ] do
        [js] = view |> render() |> Floki.parse_document!() |> Floki.find(selector) |> Floki.attribute(attribute)
        assert js =~ focus
        assert js =~ "close_image"
        refute js =~ "F_ONE"
      end

      assert has_element?(view, "#triage-image-view[phx-key='Escape']")
    end

    test "with nothing enlarged, or no thread open, image events change nothing, and one image shows no steps or position",
         %{
           conn: conn,
           thread: thread,
           shots: shots,
           single: single
         } do
      {:ok, view, _html} = live(conn, ~p"/triage/#{thread.id}")
      view |> element("#triage-panel-thread") |> render_click()
      render_hook(view, "step_image", %{"direction" => "next"})
      render_hook(view, "image_key", %{"key" => "ArrowRight"})
      refute has_element?(view, "#triage-image-view")

      view |> element("#triage-image-open-#{single.id}-F_FOUR") |> render_click()
      assert has_element?(view, "#triage-image-name", "four.png")
      refute has_element?(view, "#triage-image-previous")
      refute has_element?(view, "#triage-image-next")
      refute has_element?(view, "#triage-image-position")
      refute has_element?(view, "#triage-image-divider")

      {:ok, view, _html} = live(conn, ~p"/triage/tth_missing")
      render_hook(view, "open_image", %{"message_id" => shots.id, "file_id" => "F_ONE"})
      refute has_element?(view, "#triage-image-view")
    end

    test "a thread update keeps the view on the same image, and opening another thread closes it", %{
      conn: conn,
      workspace: workspace,
      channel: channel,
      thread: thread,
      shots: shots
    } do
      {:ok, view, _html} = live(conn, ~p"/triage/#{thread.id}")
      view |> element("#triage-panel-thread") |> render_click()
      view |> element("#triage-image-open-#{shots.id}-F_ONE") |> render_click()
      view |> element("#triage-image-next") |> render_click()

      {:ok, _thread} =
        Triage.handle_slack_event(
          workspace,
          slack_message_event(channel, %{"ts" => "1790000300.000400", "thread_ts" => thread.external_id, "text" => "+1"})
        )

      send(view.pid, {:triage_changed, thread.id})
      assert has_element?(view, "#triage-thread", "+1")
      assert has_element?(view, "#triage-image-position", "2 of 3")
      assert has_element?(view, "#triage-image-name", "two.png")

      {:ok, other} =
        Triage.handle_slack_event(workspace, slack_message_event(channel, %{"ts" => "1790000900.000100"}))

      render_patch(view, ~p"/triage/#{other.id}")
      refute has_element?(view, "#triage-image-view")
    end

    test "the page never carries Slack's file address or the bot token, and a new image shows without a reload", %{
      conn: conn,
      workspace: workspace,
      channel: channel,
      thread: thread
    } do
      {:ok, view, html} = live(conn, ~p"/triage/#{thread.id}")
      view |> element("#triage-panel-thread") |> render_click()

      refute html =~ "files.slack.com"
      refute html =~ "xoxb-bot"

      {:ok, _thread} =
        Triage.handle_slack_event(
          workspace,
          slack_message_event(channel, %{
            "subtype" => "file_share",
            "ts" => "1790000400.000500",
            "thread_ts" => thread.external_id,
            "text" => "And now",
            "files" => [
              %{
                "id" => "F_LIVE",
                "name" => "live.png",
                "mimetype" => "image/png",
                "url_private" => "https://files.slack.com/files-pri/T1-F_LIVE/live.png"
              }
            ]
          })
        )

      assert has_element?(view, "[aria-label='Enlarge live.png']")
      view |> element("[aria-label='Enlarge live.png']") |> render_click()
      refute render(view) =~ "files.slack.com"
      refute render(view) =~ "xoxb-bot"
    end
  end

  describe "a thread forwarded from Intercom" do
    setup %{user: user, project: project} do
      unique = System.unique_integer([:positive])
      app_id = "app#{unique}"

      Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => app_id}}))

      {:ok, workspace} =
        Support.create_intercom_workspace(system_scope(), project, %{
          "name" => "Dishbooks Support",
          "access_token" => "tok",
          "client_id" => "cid",
          "client_secret" => "sec"
        })

      payload = %{
        "id" => "c#{unique}",
        "created_at" => 1_790_000_000,
        "updated_at" => 1_790_000_100,
        "state" => "open",
        "source" => %{
          "id" => "s1",
          "body" => "<p>The sesame is missing and the PDF stops.</p>",
          "author" => %{"type" => "user", "name" => "Marta Kowalczyk", "email" => "marta@example.com"}
        },
        "conversation_parts" => %{
          "conversation_parts" => [
            %{
              "id" => "p1",
              "part_type" => "note",
              "created_at" => 1_790_000_100,
              "body" => "<p>Looks like a bug.</p>",
              "author" => %{"type" => "admin", "name" => "Dana Whitfield"}
            }
          ]
        }
      }

      Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, payload))
      {:ok, conversation} = Support.sync_intercom_conversation(workspace, payload["id"])

      items =
        for {key, title} <- [{"sesame", "The allergen sheet lists sesame"}, {"pdf", "The PDF prints the whole method"}] do
          %{
            "key" => key,
            "kind" => "bug",
            "title" => title,
            "verdict" => "confirmed",
            "issue" => %{"title" => title, "description" => "Seen on Intercom.", "priority" => "high"}
          }
        end

      expect(Tools, :run_agent, fn _role, _argv, _opts ->
        conversation
        |> Conversation.scratch_path()
        |> Path.join("result.json")
        |> File.write!(Jason.encode!(%{"message" => "Two bugs.", "reply" => "Passed on.", "items" => items}))

        {:ok, ""}
      end)

      {:ok, _drafting} = Support.draft_support_reply(system_scope(), conversation)
      :ok = Support.run_support_agent(conversation)

      {:ok, user} =
        Users.update_user(system_scope(), user, %{
          intercom_admin_id: "7",
          intercom_app_id: app_id,
          intercom_name: "Dana Whitfield",
          intercom_access_token: "ic-tok"
        })

      Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"type" => "conversation"}))
      {:ok, _sent} = Support.send_support_reply(Rail.Scope.for_user(user), conversation)

      [thread] =
        Repo.all(
          from t in Thread,
            where: t.support_conversation_id == ^conversation.id,
            preload: [items: ^from(i in Item, order_by: i.position)]
        )

      %{forwarded: thread, user: user}
    end

    test "shows who forwarded it, no reply box, and Create 2 tickets, with the conversation one click away", %{
      conn: conn,
      user: user,
      forwarded: %Thread{id: thread_id, permalink: permalink}
    } do
      {:ok, view, _html} = live(conn, ~p"/triage/#{thread_id}")

      assert has_element?(view, "#triage-row-#{thread_id}", "Intercom")
      assert has_element?(view, "#triage-row-#{thread_id}", "Forwarded by #{user.name}")
      assert has_element?(view, "#triage-source", "Intercom · forwarded by #{user.name}")
      assert has_element?(view, "#triage-forwarded", "Support already replied in Intercom.")
      refute has_element?(view, "#triage-reply-form")
      refute has_element?(view, "#triage-link-prompt")
      assert has_element?(view, "#triage-send-button", "Create 2 tickets")
      assert has_element?(view, "#triage-send-hint", "Creates 2 tickets in")
      assert has_element?(view, "#triage-panel-thread", "Conversation · 2")

      view |> element("#triage-panel-thread") |> render_click()
      assert has_element?(view, ~s(#open-in-slack[href="#{permalink}"]), "Open in Intercom")
      assert has_element?(view, "#triage-thread", "Internal note: Looks like a bug.")
    end

    test "Create 2 tickets creates both with what was typed, and settles the thread", %{
      conn: conn,
      forwarded: %Thread{id: thread_id, items: [first, second]}
    } do
      {:ok, view, _html} = live(conn, ~p"/triage/#{thread_id}")

      view
      |> form("#triage-ticket-form-#{first.id}", %{"item" => %{"issue_title" => "Sesame shows on the allergen sheet"}})
      |> render_change()

      view |> element("#triage-send-button") |> render_click()

      assert %Thread{status: :done} = Repo.get!(Thread, thread_id)

      assert [%Item{created_issue: %Issue{title: "Sesame shows on the allergen sheet"}}, %Item{created_issue: %Issue{}}] =
               Repo.all(
                 from i in Item, where: i.id in ^[first.id, second.id], order_by: i.position, preload: :created_issue
               )

      refute has_element?(view, "#triage-send-button")
      assert has_element?(view, "#triage-sent", "Sent: 2 tickets created.")
      assert has_element?(view, "#triage-sent", "Ask the agent in the chat to bring it back.")
      refute has_element?(view, "#triage-sent", "A new message")
    end

    test "a person who lost the project sees the thread go when they send", %{
      conn: conn,
      user: user,
      forwarded: %Thread{id: thread_id}
    } do
      {:ok, view, _html} = live(conn, ~p"/triage/#{thread_id}")

      :sys.replace_state(view.pid, fn state ->
        put_in(state.socket.assigns.current_scope, Rail.Scope.for_user(%{user | project_ids: []}))
      end)

      view |> element("#triage-send-button") |> render_click()
      refute has_element?(view, "#triage-draft-column-#{thread_id}")
    end
  end
end
