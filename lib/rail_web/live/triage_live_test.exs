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
        stage: :plan,
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
    assert has_element?(view, "#triage-item-task-#{bug.id}", "Plan")

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

    stub(Rail.Pipeline, :start_task, fn _issue, :plan -> {:ok, :started} end)
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
      assert has_element?(view, "#triage-items")

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

    test "with no thread open, or nothing enlarged, image events change nothing", %{
      conn: conn,
      thread: thread,
      shots: shots
    } do
      {:ok, view, _html} = live(conn, ~p"/triage/#{thread.id}")
      render_hook(view, "step_image", %{"direction" => "next"})
      render_hook(view, "image_key", %{"key" => "ArrowRight"})
      refute has_element?(view, "#triage-image-view")

      {:ok, view, _html} = live(conn, ~p"/triage/tth_missing")
      render_hook(view, "open_image", %{"message_id" => shots.id, "file_id" => "F_ONE"})
      refute has_element?(view, "#triage-image-view")
    end

    test "a message with one image shows no steps or position", %{conn: conn, thread: thread, single: single} do
      {:ok, view, _html} = live(conn, ~p"/triage/#{thread.id}")
      view |> element("#triage-image-open-#{single.id}-F_FOUR") |> render_click()

      assert has_element?(view, "#triage-image-name", "four.png")
      refute has_element?(view, "#triage-image-previous")
      refute has_element?(view, "#triage-image-next")
      refute has_element?(view, "#triage-image-position")
      refute has_element?(view, "#triage-image-divider")
    end

    test "a thread update keeps the view on the same image, and opening another thread closes it", %{
      conn: conn,
      workspace: workspace,
      channel: channel,
      thread: thread,
      shots: shots
    } do
      {:ok, view, _html} = live(conn, ~p"/triage/#{thread.id}")
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
end
