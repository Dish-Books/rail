defmodule RailWeb.TriageLiveTest do
  use RailWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

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

    assert has_element?(view, "#triage-verdict-#{bug.id}", "Confirmed")
    assert has_element?(view, "#triage-verdict-#{request.id}", "Partly built")
    assert has_element?(view, "#issue-title-#{bug.id}[value='Approve leaves tasks at Design']")
    assert has_element?(view, "#reply-text-#{request.id}", "Good call, Priya.")
    refute has_element?(view, "#issue-form-#{request.id}")
    assert has_element?(view, "#triage-item-#{request.id}", "Rows show no wait time.")
    assert has_element?(view, "#triage-item-#{request.id}", "lib/overview.ex")
  end

  test "an edit to a draft is saved as yours, and someone else's under their name", %{
    conn: conn,
    user: %{id: user_id},
    workspace: workspace,
    thread: %Thread{items: [bug, request]}
  } do
    {:ok, view, _html} = live(conn, ~p"/triage")

    view
    |> form("#issue-form-#{bug.id}", %{"item" => %{"issue_title" => "Approve leaves tasks stuck at Design"}})
    |> render_change()

    assert %Item{issue_title: "Approve leaves tasks stuck at Design", issue_edited_by_id: ^user_id} =
             Repo.get!(Item, bug.id)

    assert has_element?(view, "#issue-edited-#{bug.id}", "Edited by you")

    view |> form("#reply-form-#{request.id}", %{"item" => %{"reply_text" => "Good call."}}) |> render_change()
    assert has_element?(view, "#reply-edited-#{request.id}", "Edited by you")

    jordan = slack_user(workspace.external_id, "Jordan Ellis")
    {:ok, _edited} = Triage.update_triage_draft(Rail.Scope.for_user(jordan), request, %{"reply_text" => "Nice idea."})
    send(view.pid, {:triage_changed, request.thread_id})
    assert has_element?(view, "#reply-edited-#{request.id}", "Edited by Jordan Ellis")
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
        backend_id: "bkd_test_seed"
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
    |> form("#issue-form-#{bug.id}", %{"item" => %{"issue_title" => "Approve leaves tasks at Design, with no role"}})
    |> render_submit()

    assert has_element?(view, "#triage-item-#{bug.id}[data-state='settled']", "Created TRI-214 with your edits")
    assert has_element?(view, "#triage-item-task-#{bug.id}", "Product")

    view |> form("#reply-form-#{request.id}") |> render_submit()
    assert has_element?(view, "#triage-item-#{request.id}[data-state='settled']", "Reply posted by Michael")

    assert has_element?(view, "#triage-thread [data-qa='triage-message']", user.slack_name)
    assert has_element?(view, "#triage-thread [data-qa='via-rail']", "via Rail")
    assert has_element?(view, "#triage-filter-done", "Done · 1")
  end

  test "an accept that fails says why on its item", %{conn: conn, thread: %Thread{items: [bug, _request]}} do
    {:ok, view, _html} = live(conn, ~p"/triage")

    view |> form("#reply-form-#{bug.id}") |> render_submit()

    assert has_element?(view, "#triage-item-error-#{bug.id}", "create the issue first")
  end

  test "a person who has not linked Slack cannot accept, and is told how to", %{
    conn: conn,
    thread: %Thread{items: [bug, _request]} = thread
  } do
    unique = System.unique_integer([:positive])

    {:ok, unlinked} =
      Users.register_oauth_user(%{github_id: "tl_#{unique}", login: "tl_#{unique}", email: "tl#{unique}@x.com"})

    {:ok, view, _html} = live(log_in_user(conn, unlinked), ~p"/triage/#{thread.id}")

    assert has_element?(view, "#create-issue-#{bug.id}[disabled]")
    assert has_element?(view, "#post-reply-#{bug.id}[disabled]")
    assert has_element?(view, "#connect-slack-#{bug.id}", "Connect Slack to post as yourself")
  end

  test "Correct quotes the assumption, and sending the correction locks only its item", %{
    conn: conn,
    thread: %Thread{items: [bug, request]}
  } do
    {:ok, view, _html} = live(conn, ~p"/triage")

    view |> element("#correct-#{bug.id}-0") |> render_click()
    view |> form("#correction-form", %{"correction" => %{"text" => "Half typed"}}) |> render_change()
    assert has_element?(view, "#correction-text", "Half typed")
    assert has_element?(view, "#correction-assumption", "Assumed: Billing is the BILL project.")
    assert has_element?(view, "#correction-pick-#{bug.id}[aria-pressed='true']")

    view |> form("#correction-form", %{"correction" => %{"text" => "Billing has no Design role."}}) |> render_submit()

    assert has_element?(view, "#triage-item-#{bug.id}[data-state='retriaging']", "Triaging again with your correction")
    assert has_element?(view, "#triage-item-#{request.id}[data-state='open']")
    assert has_element?(view, "#triage-corrections", "You · on item 1")
    assert has_element?(view, "#triage-corrections", "Billing has no Design role.")

    bug_redone =
      triage_bug(%{
        "verdict" => "not_reproduced",
        "assumptions" => [%{"text" => "Billing has a Design role.", "corrected" => true}]
      })

    triage_with(Repo.get!(Thread, bug.thread_id), %{"items" => [bug_redone]})
    send(view.pid, {:triage_changed, bug.thread_id})

    assert has_element?(view, "#triage-redo-#{bug.id}", "Was Confirmed.")
    assert has_element?(view, "#triage-item-#{bug.id}", "Corrected by you.")
    assert has_element?(view, "#triage-corrections", "Item 1 triaged again at")

    view |> element("#correction-pick-#{request.id}") |> render_click()
    view |> form("#correction-form", %{"correction" => %{"text" => " "}}) |> render_submit()
    assert %Item{retriaging: false} = Repo.get!(Item, request.id)
  end

  test "dismissing a thread finishes it", %{conn: conn, thread: %Thread{id: thread_id, items: [bug, _request]}} do
    {:ok, view, _html} = live(conn, ~p"/triage/#{thread_id}")

    view |> element("#dismiss-thread-button") |> render_click()

    assert %Thread{status: :done} = Repo.get!(Thread, thread_id)
    refute has_element?(view, "#triage-badge")
    assert has_element?(view, "#triage-queue-empty", "Nothing is waiting on you.")
    assert has_element?(view, "#triage-queue-empty", "#rail-feedback is connected.")
    assert has_element?(view, "#triage-item-#{bug.id}[data-state='settled']", "Done")

    render_hook(view, "send_correction", %{"correction" => %{"item_id" => bug.id, "text" => "Too late"}})
    assert has_element?(view, "#triage-item-error-#{bug.id}", "settled and closed to corrections")

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
    %{workspace: workspace, channel: channel} = connect_slack_channel(project, bot_messages: true)

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

    {:ok, _issue} = Rail.Issues.create_issue(system_scope(), project, %{title: "Wait times"})

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
    refute has_element?(view, "#triage-item-#{bug.id}", "with your edits")
  end
end
