defmodule RailWeb.TriageLiveTest do
  use RailWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Triage
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users

  setup %{conn: conn} do
    %{project: project} = triage_project()
    %{workspace: workspace, channel: channel} = connect_slack_channel(project, users: %{"U_PRIYA" => "Priya Natarajan"})

    {:ok, thread} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{
          "text" => "Approved BILL-88 and it sits at Design. Could Up next show wait times?"
        })
      )

    request = %{
      "key" => "wait-times",
      "kind" => "feature_request",
      "title" => "Wait time on every Up next row",
      "verdict" => "partly_built",
      "summary" => "Ordered by wait, but rows show none.",
      "evidence" => [
        %{"file" => "lib/overview.ex", "excerpt" => "Up next is ordered longest-waiting first.", "holds" => true},
        %{"file" => "lib/up_next.ex", "lines" => "78", "excerpt" => "Rows show no wait time.", "holds" => false}
      ],
      "reply" => "Good call, Priya."
    }

    thread =
      triage_with(thread, %{
        "title" => "Tasks stuck at Design, wait times in Up next",
        "messages" => [
          %{
            "ts" => thread.external_id,
            "items" => [
              %{"key" => "stuck-at-design", "change" => "raised", "passage" => "Approved BILL-88 and it sits at Design."},
              %{"key" => "wait-times", "change" => "raised", "passage" => "Could Up next show wait times?"}
            ]
          }
        ],
        "items" => [triage_bug(), request]
      })

    user = slack_user(workspace.external_id, "Michael")
    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})

    %{
      conn: log_in_user(conn, user),
      user: user,
      project: project,
      workspace: workspace,
      channel: channel,
      thread: thread
    }
  end

  test "shows the queue, the thread with its passages marked, and every item with its drafts", %{
    conn: conn,
    thread: %Thread{id: thread_id, items: [bug, request]}
  } do
    {:ok, view, _html} = live(conn, ~p"/triage")

    assert has_element?(view, "#triage-filter-waiting", "Waiting · 1")
    assert has_element?(view, "#triage-channels", "#rail-feedback")
    assert has_element?(view, "#triage-row-#{thread_id}", "Tasks stuck at Design")
    assert has_element?(view, "#triage-row-#{thread_id}", "1 bug")
    assert has_element?(view, "#triage-row-#{thread_id}", "1 request")
    assert has_element?(view, "#triage-row-#{thread_id}", "3 to accept")
    assert has_element?(view, "#triage-badge", "1")

    assert has_element?(view, "#triage-thread mark", "Approved BILL-88 and it sits at Design.")
    assert has_element?(view, "#triage-thread mark", "Could Up next show wait times?")
    assert has_element?(view, "#triage-thread", "Priya Natarajan")
    assert has_element?(view, "#triage-thread time[phx-hook='LocalTime'][data-format='date-time']")

    assert has_element?(view, "#triage-verdict-#{bug.id}", "Confirmed")
    assert has_element?(view, "#triage-verdict-#{request.id}", "Partly built")
    assert has_element?(view, "#issue-title-#{bug.id}[value='Approve leaves tasks at Design']")
    assert has_element?(view, "#reply-text-#{request.id}", "Good call, Priya.")
    refute has_element?(view, "#issue-form-#{request.id}")
    assert has_element?(view, "#triage-item-#{request.id}", "Rows show no wait time.")
    assert has_element?(view, "#triage-item-#{request.id}", "lib/overview.ex")
  end

  test "what a person types stays on the page until a pass redrafts it, and is never saved", %{
    conn: conn,
    workspace: workspace,
    channel: channel,
    thread: %Thread{items: [bug, request]} = thread
  } do
    {:ok, view, _html} = live(conn, ~p"/triage")

    view
    |> form("#issue-form-#{bug.id}", %{"item" => %{"issue_title" => "Approve leaves tasks stuck at Design"}})
    |> render_change()

    view |> form("#reply-form-#{request.id}", %{"item" => %{"reply_text" => "Good call."}}) |> render_change()

    assert %Item{issue_title: "Approve leaves tasks at Design"} = Repo.get!(Item, bug.id)
    assert %Item{reply_text: "Good call, Priya."} = Repo.get!(Item, request.id)
    refute has_element?(view, "#triage-items", "Edited by")

    {:ok, _reply} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{"ts" => "1790000700.000100", "thread_ts" => thread.external_id, "text" => "+1"})
      )

    send(view.pid, {:triage_changed, thread.id})
    assert has_element?(view, ~s(#issue-title-#{bug.id}[value="Approve leaves tasks stuck at Design"]))
    assert has_element?(view, "#reply-text-#{request.id}", "Good call.")

    {:ok, fresh, _html} = live(conn, ~p"/triage/#{thread.id}")
    assert has_element?(fresh, ~s(#issue-title-#{bug.id}[value="Approve leaves tasks at Design"]))
    assert has_element?(fresh, "#reply-text-#{request.id}", "Good call, Priya.")

    rewritten = %{
      "key" => "wait-times",
      "kind" => "feature_request",
      "title" => "Wait time on every Up next row",
      "verdict" => "partly_built",
      "reply" => "Rail's second thought."
    }

    triage_with(Repo.get!(Thread, thread.id), %{"items" => [triage_bug(), rewritten]})
    send(view.pid, {:triage_changed, thread.id})

    assert has_element?(view, "#reply-text-#{request.id}", "Rail's second thought.")
    assert has_element?(view, ~s(#issue-title-#{bug.id}[value="Approve leaves tasks stuck at Design"]))
  end

  test "creating the issue and posting a reply settle their items, and the posts show as yours via Rail", %{
    conn: conn,
    user: user,
    project: project,
    thread: %Thread{items: [bug, request]}
  } do
    {:ok, _product} =
      Rail.Roles.create_role(system_scope(), project, %{
        stage: :product,
        name: "Product",
        model: "claude-opus-5-5",
        system_prompt: "You write tickets.",
        cli: :claude
      })

    {:ok, view, _html} = live(conn, ~p"/triage")
    Req.Test.allow(Rail.Linear, self(), view.pid)
    Req.Test.allow(Rail.Slack, self(), view.pid)
    Req.Test.allow(Rail.GitHub.Client, self(), view.pid)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_tri_214",
              "identifier" => "TRI-214",
              "title" => "Approve leaves tasks at Design",
              "url" => "https://linear.app/acme/issue/TRI-214",
              "state" => %{"id" => "st_tri", "name" => "Triage", "type" => "triage"}
            }
          }
        }
      })
    end)

    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "ts" => "1790000500.000100"}))
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "ts" => "1790000600.000100"}))

    view
    |> form("#reply-form-#{bug.id}", %{"item" => %{"reply_text" => "Fixed soon. Filed as {issue link}."}})
    |> render_change()

    view
    |> form("#issue-form-#{bug.id}", %{"item" => %{"issue_title" => "Approve leaves tasks at Design, with no role"}})
    |> render_submit()

    assert has_element?(view, "#triage-item-#{bug.id}[data-state='settled']", "Created TRI-214")
    assert has_element?(view, "#triage-item-posted-#{bug.id}", "Fixed soon. Filed as TRI-214.")
    refute has_element?(view, "#triage-item-#{bug.id}", "{issue link}")
    assert has_element?(view, "#triage-item-task-#{bug.id}", "Product")

    view |> form("#reply-form-#{request.id}") |> render_submit()
    assert has_element?(view, "#triage-item-#{request.id}[data-state='settled']", "Reply posted by Michael")
    assert has_element?(view, "#reply-posted-time-#{request.id}[phx-hook='LocalTime']")

    assert has_element?(view, "#triage-thread [data-qa='triage-message']", user.slack_name)
    assert has_element?(view, "#triage-thread [data-qa='via-rail']", "via Rail")
    assert has_element?(view, "#triage-filter-done", "Done · 1")
  end

  test "an accept that fails says why on its item", %{conn: conn, thread: %Thread{items: [bug, _request]}} do
    {:ok, view, _html} = live(conn, ~p"/triage")

    view |> form("#reply-form-#{bug.id}") |> render_submit()

    assert has_element?(view, "#triage-item-error-#{bug.id}", "create the issue first")
  end

  test "marking the channel external changes an open item's issue line, and a reply that links the issue is refused", %{
    conn: conn,
    project: project,
    channel: channel,
    thread: %Thread{items: [bug, _request]}
  } do
    {:ok, view, _html} = live(conn, ~p"/triage")
    assert has_element?(view, "#issue-line-#{bug.id}", "starts Product · link posted in thread")

    {:ok, _project} =
      Projects.update_project(system_scope(), project, %{
        "slack_channels" => [
          %{
            "id" => channel.id,
            "external_id" => channel.external_id,
            "name" => channel.name,
            "slack_workspace_id" => channel.slack_workspace_id,
            "external" => "true"
          }
        ]
      })

    assert has_element?(view, "#issue-line-#{bug.id}", "starts Product · no link posted, external channel")
    refute has_element?(view, "#issue-line-#{bug.id}", "link posted in thread")

    refusal = "This reply cannot link the issue in an external channel. Take out {issue link} to post it."
    view |> form("#reply-form-#{bug.id}") |> render_submit()
    assert has_element?(view, "#triage-item-error-#{bug.id}", refusal)

    {:ok, view, _html} = live(conn, ~p"/triage")
    refute has_element?(view, "#triage-item-error-#{bug.id}")
    view |> form("#issue-form-#{bug.id}") |> render_submit()
    assert has_element?(view, "#triage-item-error-#{bug.id}", refusal)
    assert %Item{created_issue_id: nil, issue_created_by_id: nil} = Repo.get!(Item, bug.id)
  end

  test "a person who has not linked Slack cannot accept, and is told how to", %{
    conn: conn,
    project: project,
    thread: %Thread{items: [bug, _request]} = thread
  } do
    unique = System.unique_integer([:positive])

    {:ok, unlinked} =
      Users.register_oauth_user(%{github_id: "tl_#{unique}", login: "tl_#{unique}", email: "tl#{unique}@x.com"})

    {:ok, unlinked} = Users.update_user(system_scope(), unlinked, %{project_ids: [project.id]})

    {:ok, view, _html} = live(log_in_user(conn, unlinked), ~p"/triage/#{thread.id}")

    assert has_element?(view, "#create-issue-#{bug.id}[disabled]")
    assert has_element?(view, "#post-reply-#{bug.id}[disabled]")
    assert has_element?(view, "#connect-slack-#{bug.id}", "Connect Slack to post as yourself")
  end

  test "Correct quotes the assumption in a note, and adding the note locks only its item", %{
    conn: conn,
    thread: %Thread{items: [bug, request]}
  } do
    {:ok, view, _html} = live(conn, ~p"/triage")

    view |> element("#correct-#{bug.id}-0") |> render_click()
    view |> form("#note-form", %{"note" => %{"text" => "Half typed"}}) |> render_change()
    assert has_element?(view, "#note-text", "Half typed")
    assert has_element?(view, "#note-assumption", "Assumed: Billing is the BILL project.")
    assert has_element?(view, "#note-pick-#{bug.id}[aria-pressed='true']")

    view |> form("#note-form", %{"note" => %{"text" => "Billing has no Design role."}}) |> render_submit()

    assert has_element?(view, "#triage-item-#{bug.id}[data-state='retriaging']", "Triaging again with your note")
    assert has_element?(view, "#triage-item-#{request.id}[data-state='open']")
    assert has_element?(view, "#triage-notes", "You · on item 1")
    assert has_element?(view, "#triage-notes", "Billing has no Design role.")

    bug_redone =
      triage_bug(%{
        "verdict" => "not_reproduced",
        "assumptions" => [%{"text" => "Billing has a Design role.", "corrected" => true}]
      })

    triage_with(Repo.get!(Thread, bug.thread_id), %{"items" => [bug_redone]})
    send(view.pid, {:triage_changed, bug.thread_id})

    assert has_element?(view, "#triage-redo-#{bug.id}", "Was Confirmed.")
    assert has_element?(view, "#triage-item-#{bug.id}", "Corrected by you.")
    assert has_element?(view, "#triage-notes", "Item 1 triaged again at")
    assert has_element?(view, "#triage-notes time[phx-hook='LocalTime']")

    view |> element("#note-pick-#{request.id}") |> render_click()
    view |> form("#note-form", %{"note" => %{"text" => " "}}) |> render_submit()
    assert %Item{retriaging: false} = Repo.get!(Item, request.id)

    assert has_element?(view, "#note-form", "Never posted to Slack")
    assert has_element?(view, "#add-note-button", "Add note")
    refute has_element?(view, "#note-assumption")

    view |> form("#note-form", %{"note" => %{"text" => "Customers asked for this twice this week."}}) |> render_submit()
    assert %Item{retriaging: true} = Repo.get!(Item, request.id)
    assert has_element?(view, "#triage-notes", "Customers asked for this twice this week.")
  end

  test "dismissing a thread finishes it", %{conn: conn, thread: %Thread{id: thread_id, items: [bug, _request]}} do
    {:ok, view, _html} = live(conn, ~p"/triage/#{thread_id}")

    view |> element("#dismiss-thread-button") |> render_click()

    assert %Thread{status: :done} = Repo.get!(Thread, thread_id)
    refute has_element?(view, "#triage-badge")
    assert has_element?(view, "#triage-queue-empty", "Nothing is waiting on you.")
    assert has_element?(view, "#triage-queue-empty", "#rail-feedback is connected.")
    assert has_element?(view, "#triage-item-#{bug.id}[data-state='settled']", "Done")

    render_hook(view, "add_note", %{"note" => %{"item_id" => bug.id, "text" => "Too late"}})
    assert has_element?(view, "#triage-item-error-#{bug.id}", "settled and takes no more notes")

    view |> element("#triage-filter-done") |> render_click()
    assert_patch(view, ~p"/triage?filter=done")
    assert has_element?(view, "#triage-row-#{thread_id}", "Dismissed by Michael")
  end

  test "a thread that needed no response offers Triage anyway", %{
    conn: conn,
    workspace: workspace,
    channel: channel
  } do
    {:ok, thread} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{"ts" => "1790009000.000100", "text" => "sync at 11:30?"})
      )

    thread =
      triage_with(thread, %{
        "messages" => [%{"ts" => "1790009000.000100", "needs_response" => false, "reason" => "Scheduling"}],
        "items" => []
      })

    {:ok, view, _html} = live(conn, ~p"/triage/#{thread.id}?filter=done")

    assert has_element?(view, "#triage-row-#{thread.id}", "Needed no response")
    assert has_element?(view, "#triage-no-response", "Scheduling")
    assert has_element?(view, "#triage-thread", "Needs no response. Nothing drafted.")

    view |> element("#triage-anyway-button") |> render_click()

    assert %Thread{status: :triaging, forced: true} = Repo.get!(Thread, thread.id)
    assert has_element?(view, "#triage-running")
  end

  test "a failed pass shows why and can be run again", %{conn: conn, thread: %Thread{id: thread_id}} do
    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [error: "This project has no Triage role."])

    {:ok, view, _html} = live(conn, ~p"/triage/#{thread_id}")
    assert has_element?(view, "#triage-error", "This project has no Triage role.")

    view |> element("#triage-again-button") |> render_click()
    assert %Thread{error: nil, status: :triaging} = Repo.get!(Thread, thread_id)
  end

  test "a bot's post shows its name and APP", %{conn: conn, project: project} do
    %{workspace: workspace, channel: channel} = connect_slack_channel(project, bot_triage_enabled: true)

    {:ok, thread} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{"bot_id" => "B_PH", "username" => "PostHog", "text" => "TypeError"})
      )

    {:ok, view, _html} = live(conn, ~p"/triage/#{thread.id}?filter=triaging")

    assert has_element?(view, "#triage-thread [data-qa='triage-message']", "PostHog")
    assert has_element?(view, "#triage-thread [data-qa='triage-message']", "APP")

    triage_with(thread, %{"items" => [triage_bug(%{"reply" => nil})]})
    send(view.pid, {:triage_changed, thread.id})
    view |> element("#triage-filter-waiting") |> render_click()
    assert has_element?(view, "#triage-row-#{thread.id}", "Confirmed")
  end

  test "an announced change re-renders the page", %{conn: conn, thread: %Thread{id: thread_id}} do
    {:ok, view, _html} = live(conn, ~p"/triage")

    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [title: "Renamed elsewhere"])
    send(view.pid, {:triage_changed, thread_id})
    send(view.pid, {:issue_created, "iss_any"})

    assert has_element?(view, "#triage-thread-title", "Renamed elsewhere")
  end

  test "a project the user cannot access is left out of the queue, the counts and a link to its thread", %{
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

    refute has_element?(view, "#triage-thread")
    refute html =~ "A secret request"
    refute render(view) =~ "Hidden thread"
  end

  test "an unknown thread opens nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/triage/tth_missing?filter=bogus")

    refute has_element?(view, "#triage-thread")
  end

  test "an item an existing issue covers shows it is tracked, and settles once its reply is posted", %{
    conn: conn,
    project: project,
    workspace: workspace,
    channel: channel
  } do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_23",
              "identifier" => "TRI-23",
              "title" => "Wait times",
              "state" => %{"type" => "triage"}
            }
          }
        }
      })
    end)

    {:ok, %{id: tracked_issue_id}} = Rail.Issues.create_issue(system_scope(), project, %{title: "Wait times"})

    {:ok, thread} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{"ts" => "1790007000.000100", "text" => "wait?"})
      )

    tracked = %{
      "key" => "wait-times",
      "kind" => "feature_request",
      "title" => "Wait times",
      "verdict" => "not_built",
      "existing_issue" => "TRI-23",
      "reply" => "Tracked in TRI-23, which is in Triage."
    }

    %Thread{items: [item]} = triage_with(thread, %{"items" => [tracked]})

    {:ok, view, _html} = live(conn, ~p"/triage/#{thread.id}")
    assert has_element?(view, "#triage-tracked-#{item.id}", "Already tracked, no new issue:")
    assert has_element?(view, "#triage-tracked-#{item.id}", "TRI-23")
    assert has_element?(view, "#triage-tracked-link-#{item.id}[href='/issues/#{tracked_issue_id}']")
    refute has_element?(view, "#issue-form-#{item.id}")

    Req.Test.allow(Rail.Slack, self(), view.pid)
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "ts" => "1790007100.000100"}))
    view |> form("#reply-form-#{item.id}") |> render_submit()

    assert has_element?(view, "#triage-item-#{item.id}[data-state='settled']", "in TRI-23")
  end

  test "an issue created whose post then fails says so, and keeps its reply to send", %{
    conn: conn,
    thread: %Thread{items: [bug, _request]}
  } do
    {:ok, view, _html} = live(conn, ~p"/triage")
    Req.Test.allow(Rail.Linear, self(), view.pid)
    Req.Test.allow(Rail.Slack, self(), view.pid)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_77", "identifier" => "TRI-77", "title" => "T", "state" => %{"type" => "triage"}}
          }
        }
      })
    end)

    stub(Rail.Pipeline, :start_task, fn _issue, :product -> {:ok, :started} end)
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "not_in_channel"}))

    view |> form("#issue-form-#{bug.id}") |> render_submit()

    assert has_element?(view, "#triage-item-#{bug.id}[data-state='open']", "Created TRI-77")
    assert has_element?(view, "#triage-item-error-#{bug.id}", "could not post in Slack")
    assert has_element?(view, "#reply-form-#{bug.id}")

    Req.Test.expect(Rail.Slack, fn conn ->
      assert %{"text" => "Thanks Priya, we reproduced this. Filed as TRI-77."} =
               conn |> Req.Test.raw_body() |> Jason.decode!()

      Req.Test.json(conn, %{"ok" => true, "ts" => "1790008000.000100"})
    end)

    view |> form("#reply-form-#{bug.id}") |> render_submit()
    assert has_element?(view, "#triage-item-#{bug.id}[data-state='settled']", "Created TRI-77")
  end
end
