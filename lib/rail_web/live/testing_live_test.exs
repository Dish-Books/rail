defmodule RailWeb.TestingLiveTest do
  use RailWeb.ConnCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Phoenix.LiveViewTest

  alias Rail.Issues
  alias Rail.Issues.Clients.R2
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.TestingImage
  alias Rail.Issues.Workers.LinkTrackerUrl
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Users

  @done %{id: "done", name: "Done", state: :done}

  setup %{conn: conn} do
    [here, there, hidden] =
      for name <- ["Here", "There", "Hidden"] do
        key = "Tl#{System.unique_integer([:positive])}"

        {:ok, project} =
          Projects.create_project(system_scope(), %{
            name: name,
            github_repo: "example/#{key}",
            github_installation_id: 1,
            key: key,
            default_branch: "main",
            clone_path: "/tmp/#{key}"
          })

        project
      end

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_#{here.key}",
        login: "tester_#{here.key}",
        name: "Tester",
        email: "#{here.key}@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [here.id, there.id]})

    # Blockers are read only when a test here asks.
    stub(Issues, :get_blockers, fn _issues -> %{} end)

    done = fn project, title ->
      {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: title, description: "What it does"})
      {:ok, done} = Issues.set_issue_status(system_scope(), issue, @done)
      done
    end

    %{conn: log_in_user(conn, user), here: here, there: there, hidden: hidden, done: done, user: user}
  end

  test "an empty queue says how a ticket joins it, and one moved into Done elsewhere shows without a reload", %{
    conn: conn,
    here: here
  } do
    {:ok, view, _html} = live(conn, ~p"/testing")

    assert has_element?(view, "#section-title", "Testing")
    assert has_element?(view, "#nav-testing[data-active='true']")
    assert has_element?(view, "#testing-queue-count", "0 to test")
    assert has_element?(view, "#testing-queue-empty", "Nothing is waiting for testing.")
    assert has_element?(view, "#testing-queue-empty", "A ticket joins this queue when it moves to Done.")
    refute has_element?(view, "#testing-bar")

    {:ok, issue} = Issues.create_issue(system_scope(), here, %{title: "Merged on GitHub"})
    refute has_element?(view, "#testing-row-#{issue.id}")

    {:ok, _done} = Issues.set_issue_status(system_scope(), issue, @done)

    assert has_element?(view, "#testing-row-#{issue.id}", "Merged on GitHub")
    assert has_element?(view, "#testing-row-#{issue.id} [data-testing-state='waiting']", "Waiting")
    assert has_element?(view, "#testing-row-#{issue.id}", "Here")
    assert has_element?(view, "#testing-queue-split", "1 waiting · 0 in testing")
    assert has_element?(view, "#testing-bar", issue.identifier)
  end

  test "a Done ticket with no completed time is queued with no age", %{conn: conn, done: done, here: here} do
    issue = done.(here, "Finished before times were kept")
    issue |> Ecto.Changeset.change(completed_at: nil) |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/testing")

    assert has_element?(view, "#testing-row-#{issue.id}", "Finished before times were kept")
    refute has_element?(view, "#testing-row-#{issue.id}", " ago")
  end

  test "a ticket reopened before it was tested comes back with its notes, and a Tested one stays out", %{
    conn: conn,
    done: done,
    here: here
  } do
    in_progress = %{id: "in_progress", name: "In Progress", state: :in_progress}
    halfway = done.(here, "Reopened halfway")
    tested = done.(here, "Reopened after testing")
    {:ok, halfway} = Issues.save_testing_notes(system_scope(), halfway, "Halfway")
    {:ok, tested} = Issues.mark_issue_tested(system_scope(), tested)
    {:ok, view, _html} = live(conn, ~p"/testing")
    assert has_element?(view, "#testing-row-#{halfway.id}")
    refute has_element?(view, "#testing-row-#{tested.id}")

    {:ok, reopened} = Issues.set_issue_status(system_scope(), halfway, in_progress)
    refute has_element?(view, "#testing-row-#{halfway.id}")

    {:ok, _done} = Issues.set_issue_status(system_scope(), reopened, @done)
    assert has_element?(view, "#testing-row-#{halfway.id} [data-testing-state='testing']")

    view |> element("#testing-row-#{halfway.id}") |> render_click()
    assert has_element?(view, "#testing-notes-#{halfway.id}", "Halfway")

    {:ok, reopened} = Issues.set_issue_status(system_scope(), tested, in_progress)
    {:ok, _done} = Issues.set_issue_status(system_scope(), reopened, @done)
    refute has_element?(view, "#testing-row-#{tested.id}")
  end

  test "the queue lists the projects the user can see, oldest Done first, narrowed by the switcher", %{
    conn: conn,
    done: done,
    here: here,
    there: there,
    hidden: hidden
  } do
    older = done.(here, "Older")
    newer = done.(there, "Newer")
    secret = done.(hidden, "Secret")

    {:ok, view, html} = live(conn, ~p"/testing")

    assert [_before, after_older] = String.split(html, ~s(id="testing-row-#{older.id}"))
    assert after_older =~ ~s(id="testing-row-#{newer.id}")
    refute has_element?(view, "#testing-row-#{secret.id}")
    assert has_element?(view, "#testing-row-#{older.id}[aria-current='true']")

    conn = Plug.Conn.put_session(conn, :selected_project_id, there.id)
    {:ok, narrowed, _html} = live(conn, ~p"/testing")

    assert has_element?(narrowed, "#testing-row-#{newer.id}")
    refute has_element?(narrowed, "#testing-row-#{older.id}")
  end

  test "the open ticket shows what its issue page shows, with nothing to change but the notes", %{
    conn: conn,
    done: done,
    here: here,
    user: user
  } do
    issue = done.(here, "Read it all")
    {:ok, child} = Issues.create_issue(system_scope(), here, %{title: "A part of it", parent: issue})
    {:ok, _comment} = Issues.comment(Rail.Scope.for_user(user), issue, %{body: "Tried it on staging"})

    blocker = %Issue{identifier: "BLK-1", title: "Blocking it", state: :todo, id: "iss_tl_b"}

    stub(Issues, :get_blockers, fn [%Issue{id: id}] when id == issue.id ->
      %{id => %{blocked_by: [%{issue: blocker, in_project: true}], blocks: []}}
    end)

    assert :ok =
             perform_job(LinkTrackerUrl, %{
               issue_id: issue.id,
               url: "https://slack.example/archives/C1/p1",
               title: "Slack thread"
             })

    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    render_async(view)

    assert has_element?(view, "a[id^='issue-link-'][href='https://slack.example/archives/C1/p1']", "Slack thread")
    assert has_element?(view, "#issue-title", "Read it all")
    assert has_element?(view, "#issue-description", "What it does")
    assert has_element?(view, "#issue-status", "Done")
    assert has_element?(view, "#issue-owner", "Unassigned")
    assert has_element?(view, "#issue-testing [data-testing-state='waiting']")
    assert has_element?(view, "#issue-sub-issues", child.identifier)
    assert has_element?(view, "#issue-blocked-by", "Blocking it")
    assert has_element?(view, "#issue-comments", "Tried it on staging")
    assert has_element?(view, "#testing-open-issue[href='/issues/#{issue.identifier}']")

    refute has_element?(view, "#issue-status-picker-#{issue.id}")
    refute has_element?(view, "#issue-owner-menu")
    refute has_element?(view, "#issue-comment-form")
    refute has_element?(view, "[id^='comment-reply-form-']")
    refute has_element?(view, "#issue-start")
    refute has_element?(view, "#testing-ticket [contenteditable]")
    refute has_element?(view, "#issue-description-editor-#{issue.id}")
    refute has_element?(view, "#issue-priority-menu")
    refute has_element?(view, "#issue-estimate-menu")
    refute has_element?(view, "#issue-parent-picker-#{issue.id}")
    refute has_element?(view, "#issue-relation-pickers")
    refute has_element?(view, "[phx-click='remove_relation']")
    assert [_only] = view |> element("#testing-ticket") |> render() |> Floki.parse_fragment!() |> Floki.find("textarea")

    assert :ok = perform_job(LinkTrackerUrl, %{issue_id: issue.id, url: "https://example.com/spec", title: "Spec"})
    assert has_element?(view, "a[id^='issue-link-'][href='https://example.com/spec']", "Spec")
  end

  test "a ticket in a project the user cannot open, or one that does not exist, opens nothing", %{
    conn: conn,
    done: done,
    hidden: hidden
  } do
    secret = done.(hidden, "Secret")

    {:ok, view, _html} = live(conn, ~p"/testing/#{secret.id}")
    refute has_element?(view, "#testing-bar")
    refute has_element?(view, "#issue-page")

    {:ok, view, _html} = live(conn, ~p"/testing/iss_nothing")
    refute has_element?(view, "#testing-bar")
  end

  test "typing notes saves them, moves the ticket to In testing and keeps them over a remount", %{
    conn: conn,
    done: done,
    here: here
  } do
    issue = done.(here, "Notes")
    other = done.(here, "Untouched")
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")

    assert has_element?(view, "#testing-notes-status", "Saves as you type")
    assert has_element?(view, "#testing-send-to-triage[disabled]")
    assert has_element?(view, "#testing-bar-state[data-testing-state='waiting']")

    view
    |> form("#testing-notes-form-#{issue.id}", %{issue_id: issue.id, notes: "Six icons fit on the row"})
    |> render_change()

    assert %Issue{testing_state: :testing, testing_notes: "Six icons fit on the row"} = Repo.get!(Issue, issue.id)
    assert has_element?(view, "#testing-bar-state[data-testing-state='testing']")
    assert has_element?(view, "#testing-row-#{issue.id} [data-testing-state='testing']")
    refute has_element?(view, "#testing-send-to-triage[disabled]")
    assert has_element?(view, "#testing-queue-split", "1 waiting · 1 in testing")

    {:ok, again, _html} = live(conn, ~p"/testing/#{issue.id}")
    assert has_element?(again, "#testing-notes-#{issue.id}", "Six icons fit on the row")
    assert %Issue{testing_state: :waiting} = Repo.get!(Issue, other.id)
  end

  test "a picture added to the notes shows in their box once stored, and comes out again on remove", %{
    conn: conn,
    done: done,
    here: here
  } do
    issue = done.(here, "Pictured")
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    form = "#testing-notes-form-#{issue.id}"

    Req.Test.expect(R2, fn r2 ->
      assert ["image/png"] = Plug.Conn.get_req_header(r2, "content-type")
      Plug.Conn.send_resp(r2, 200, "")
    end)

    shot =
      file_input(view, form, :testing_images, [%{name: "row.png", content: :binary.copy("P", 1000), type: "image/png"}])

    render_upload(shot, "row.png", 50)
    assert has_element?(view, "#testing-images [id^='testing-upload-'][title='row.png']")
    render_upload(shot, "row.png", 50)
    render_async(view)

    assert %Issue{testing_state: :testing, testing_images: [%TestingImage{name: "row.png", url: url}]} =
             Repo.get!(Issue, issue.id)

    assert has_element?(view, "#testing-image-0[title='row.png'] img[src='#{url}']")
    assert has_element?(view, "#testing-bar-state[data-testing-state='testing']")
    refute has_element?(view, "[id^='testing-upload-']")

    view |> element("#testing-image-0 [data-qa='image-chip-remove']") |> render_click()

    refute has_element?(view, "#testing-images")
    assert %Issue{testing_images: []} = Repo.get!(Issue, issue.id)
  end

  test "a file the box cannot take says why and is not kept", %{
    conn: conn,
    done: done,
    here: here
  } do
    issue = done.(here, "Refused")
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    form = "#testing-notes-form-#{issue.id}"

    view
    |> file_input(form, :testing_images, [%{name: "notes.txt", content: "text", type: "text/plain"}])
    |> preflight_upload()

    view |> element(form) |> render_change(%{"_target" => ["testing_images"]})

    assert has_element?(view, "#testing-image-error", "notes.txt is not a PNG, JPEG, GIF or WebP picture.")
    refute has_element?(view, "#testing-images")
  end

  test "a picture over 10 MB, or past the tenth, is not added", %{conn: conn, done: done, here: here} do
    issue = done.(here, "Too many")
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    form = "#testing-notes-form-#{issue.id}"

    view
    |> file_input(form, :testing_images, [%{name: "huge.png", content: :binary.copy("P", 10_000_001), type: "image/png"}])
    |> preflight_upload()

    view |> element(form) |> render_change(%{"_target" => ["testing_images"]})
    assert has_element?(view, "#testing-image-error", "huge.png is over 10 MB, so it was not added.")

    eleven = for n <- 1..11, do: %{name: "shot#{n}.png", content: "PNG", type: "image/png"}
    view |> file_input(form, :testing_images, eleven) |> preflight_upload()
    view |> element(form) |> render_change(%{"_target" => ["testing_images"]})
    assert has_element?(view, "#testing-image-error", "Up to 10 pictures go at a time, so shot11.png was not added.")
  end

  test "a picture R2 fails to store, or one for a ticket finished meanwhile, says so", %{
    conn: conn,
    done: done,
    here: here
  } do
    issue = done.(here, "Failing")
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    form = "#testing-notes-form-#{issue.id}"

    Req.Test.expect(R2, &Plug.Conn.send_resp(&1, 500, "down"))

    view
    |> file_input(form, :testing_images, [%{name: "a.png", content: "PNG", type: "image/png"}])
    |> render_upload("a.png")

    render_async(view)
    assert has_element?(view, "#testing-image-error", "Couldn't add a.png. Try adding it again.")

    Req.Test.expect(R2, fn r2 ->
      {:ok, _tested} = Issues.mark_issue_tested(system_scope(), issue)
      Plug.Conn.send_resp(r2, 200, "")
    end)

    view
    |> file_input(form, :testing_images, [%{name: "b.png", content: "PNG", type: "image/png"}])
    |> render_upload("b.png")

    render_async(view)
    assert has_element?(view, "#testing-image-error", "b.png was not added: testing on this ticket has finished.")
  end

  test "removing a picture from a ticket finished in another tab says so", %{conn: conn, done: done, here: here} do
    issue = done.(here, "Finished elsewhere")

    {:ok, _pictured} =
      issue
      |> Issue.testing_images_changeset([%TestingImage{url: "https://x/a.png", name: "a.png"}])
      |> Repo.update()

    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    {:ok, _tested} = Issues.mark_issue_tested(system_scope(), issue)

    # The finished ticket's page drops the button, so this is a click sent before it did.
    render_click(view, "remove_testing_image", %{"issue_id" => issue.id, "url" => "https://x/a.png"})

    assert has_element?(view, "#testing-notice", "was already marked tested")
    assert %Issue{testing_images: [%TestingImage{name: "a.png"}]} = Repo.get!(Issue, issue.id)
  end

  test "a picture shows from its address, and a finished ticket's cannot be removed", %{
    conn: conn,
    done: done,
    here: here
  } do
    issue = done.(here, "Pictured")

    {:ok, _pictured} =
      issue
      |> Issue.testing_images_changeset([%TestingImage{url: "https://x/a/b/shot.png", name: "shot.png"}])
      |> Repo.update()

    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    assert has_element?(view, "#testing-image-0 img[src='https://x/a/b/shot.png']")
    assert has_element?(view, "#testing-image-0 [data-qa='image-chip-remove']")

    {:ok, _tested} = Issues.mark_issue_tested(system_scope(), issue)
    {:ok, finished, _html} = live(conn, ~p"/testing/#{issue.id}")

    assert has_element?(finished, "#testing-image-0")
    refute has_element?(finished, "#testing-image-0 [data-qa='image-chip-remove']")
    refute has_element?(finished, "#testing-attach-image")
    assert render_click(finished, "remove_testing_image", %{"issue_id" => "iss_other", "url" => "x"})
  end

  test "opening a ticket without typing leaves it Waiting", %{conn: conn, done: done, here: here} do
    issue = done.(here, "Only looked")
    {:ok, _view, _html} = live(conn, ~p"/testing/#{issue.id}")
    assert %Issue{testing_state: :waiting, testing_notes: nil} = Repo.get!(Issue, issue.id)
  end

  test "notes another tab saves show on an open page, and a save flushed after a switch goes to its own ticket", %{
    conn: conn,
    done: done,
    here: here
  } do
    issue = done.(here, "Shared")
    other = done.(here, "Switched to")
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")

    {:ok, _saved} = Issues.save_testing_notes(system_scope(), issue, "From the other tab")
    assert has_element?(view, "#testing-notes-#{issue.id}", "From the other tab")

    {:ok, _saved} = Issues.save_testing_notes(system_scope(), other, "Another ticket's notes")
    assert has_element?(view, "#testing-notes-#{issue.id}", "From the other tab")

    render_hook(view, "save_notes", %{"issue_id" => other.id, "notes" => "Typed before switching"})
    assert %Issue{testing_notes: "Typed before switching"} = Repo.get!(Issue, other.id)
    assert has_element?(view, "#testing-notes-#{issue.id}", "From the other tab")

    render_hook(view, "save_notes", %{"issue_id" => "iss_elsewhere", "notes" => "Lost"})
    assert has_element?(view, "#testing-bar", issue.identifier)
  end

  test "Mark tested opens the next ticket, and the last one leaves the queue empty", %{
    conn: conn,
    done: done,
    here: here
  } do
    first = done.(here, "First")
    second = done.(here, "Second")
    {:ok, view, _html} = live(conn, ~p"/testing/#{second.id}")

    view |> element("#testing-mark-tested") |> render_click()

    assert_patch(view, ~p"/testing/#{first.id}", 1_000)
    assert %Issue{state: :done, testing_state: :tested} = Repo.get!(Issue, second.id)
    refute has_element?(view, "#testing-row-#{second.id}")
    refute has_element?(view, "#testing-notice")

    view |> element("#testing-mark-tested") |> render_click()

    assert_patch(view, ~p"/testing", 1_000)
    assert has_element?(view, "#testing-queue-empty")
    refute has_element?(view, "#testing-bar")
  end

  test "a second click meant for a ticket the page has moved on from does nothing", %{
    conn: conn,
    done: done,
    here: here
  } do
    first = done.(here, "First")
    second = done.(here, "Second")
    {:ok, view, _html} = live(conn, ~p"/testing/#{first.id}")

    view |> element("#testing-mark-tested") |> render_click()
    assert_patch(view, ~p"/testing/#{second.id}", 1_000)

    render_hook(view, "mark_tested", %{"issue_id" => first.id})
    render_hook(view, "send_to_triage", %{"issue_id" => first.id})

    assert %Issue{testing_state: :waiting} = Repo.get!(Issue, second.id)
    refute has_element?(view, "#testing-notice")
  end

  test "Send to triage opens the next ticket with a notice linking the new one", %{
    conn: conn,
    done: done,
    here: here
  } do
    sent = done.(here, "Broken")
    next = done.(here, "Next")
    {:ok, view, _html} = live(conn, ~p"/testing/#{sent.id}")

    view
    |> form("#testing-notes-form-#{sent.id}", %{issue_id: sent.id, notes: "The row is cut off"})
    |> render_change()

    view |> element("#testing-send-to-triage") |> render_click()

    assert_patch(view, ~p"/testing/#{next.id}", 1_000)
    assert %Issue{state: :done, testing_state: :sent_to_triage} = Repo.get!(Issue, sent.id)

    assert %{issues: [%Issue{identifier: created, description: "The row is cut off" <> _link}]} =
             Issues.list_issues(project_id: here.id, state: :todo)

    assert has_element?(view, "#testing-notice", "#{sent.identifier} sent to triage as #{created}.")
    assert has_element?(view, "#testing-notice-created[href='/issues/#{created}']")

    view |> element("#testing-row-#{next.id}") |> render_click()
    assert has_element?(view, "#testing-notice")

    view |> element("#testing-mark-tested") |> render_click()
    assert_patch(view, ~p"/testing", 1_000)
    refute has_element?(view, "#testing-notice")
  end

  test "Send to triage on the last ticket keeps its notice over the empty queue", %{conn: conn, done: done, here: here} do
    sent = done.(here, "Last")
    {:ok, _noted} = Issues.save_testing_notes(system_scope(), sent, "Broken")
    {:ok, view, _html} = live(conn, ~p"/testing")

    view |> element("#testing-send-to-triage") |> render_click()

    assert has_element?(view, "#testing-advancing", "Updating the queue...")
    assert_patch(view, ~p"/testing", 1_000)
    assert has_element?(view, "#testing-notice", "sent to triage as")
    assert has_element?(view, "#testing-queue-empty")
  end

  test "a finished action shows a loading screen that ignores a second click", %{conn: conn, done: done, here: here} do
    first = done.(here, "First")
    second = done.(here, "Second")
    third = done.(here, "Third")
    {:ok, _noted} = Issues.save_testing_notes(system_scope(), first, "Broken")
    {:ok, view, _html} = live(conn, ~p"/testing/#{first.id}")

    view |> element("#testing-send-to-triage") |> render_click()

    assert has_element?(view, "#testing-advancing", "Opening #{second.identifier}...")
    refute has_element?(view, "#testing-send-to-triage")
    refute has_element?(view, "#testing-mark-tested")

    render_hook(view, "send_to_triage", %{"issue_id" => first.id})

    assert_patch(view, ~p"/testing/#{second.id}", 1_000)
    assert has_element?(view, "#testing-notice", "sent to triage as")
    assert %{total: 1} = Issues.list_issues(project_id: here.id, state: :todo)

    view |> element("#testing-mark-tested") |> render_click()

    assert has_element?(view, "#testing-advancing", "Opening #{third.identifier}...")
    assert_patch(view, ~p"/testing/#{third.id}", 1_000)
    assert %Issue{testing_state: :tested} = Repo.get!(Issue, second.id)
    assert %Issue{testing_state: :waiting} = Repo.get!(Issue, third.id)
  end

  test "clicking a row during the loading screen opens that row and cancels the move", %{
    conn: conn,
    done: done,
    here: here
  } do
    first = done.(here, "First")
    _second = done.(here, "Second")
    third = done.(here, "Third")
    {:ok, view, _html} = live(conn, ~p"/testing/#{first.id}")

    view |> element("#testing-mark-tested") |> render_click()
    assert has_element?(view, "#testing-advancing")

    view |> element("#testing-row-#{third.id}") |> render_click()
    assert_patch(view, ~p"/testing/#{third.id}")

    # Past the loading screen's own wait, so its move would have been sent by now.
    Process.sleep(600)
    assert has_element?(view, "#testing-bar", third.identifier)
    refute_patched(view)
  end

  test "leaving the notes field shows the notes saved last", %{conn: conn, done: done, here: here} do
    issue = done.(here, "Two testers")
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")

    view
    |> form("#testing-notes-form-#{issue.id}", %{issue_id: issue.id, notes: "Mine"})
    |> render_change()

    assert has_element?(view, "#testing-notes-#{issue.id}[data-rev='0']")
    {:ok, _theirs} = Issues.save_testing_notes(system_scope(), issue, "Theirs, saved last")

    view |> element("#testing-notes-#{issue.id}") |> render_blur()

    assert has_element?(view, "#testing-notes-#{issue.id}[data-rev='1']", "Theirs, saved last")
  end

  test "a ticket shows its cycle with no cycle menu", %{conn: conn, done: done, here: here} do
    # Cycle 1 runs Nov 10 to 23.
    :ok = Issues.close_cycle_day(~D[2026-11-10])
    stub(Date, :utc_today, fn -> ~D[2026-11-12] end)
    {:ok, %{cycles: [cycle | _later]}} = Issues.get_cycles(here)
    planned = done.(here, "Planned")
    {:ok, _planned} = Issues.set_issue_cycle(system_scope(), planned, cycle.id)
    unplanned = done.(here, "Unplanned")

    {:ok, view, _html} = live(conn, ~p"/testing/#{planned.id}")

    assert has_element?(view, "#issue-cycle", "Cycle 1")
    assert has_element?(view, "#issue-cycle", "Nov 10 – Nov 23")
    refute has_element?(view, "button#issue-cycle")
    refute has_element?(view, "#issue-cycle-menu")

    {:ok, _cycle} = Issues.update_cycle(system_scope(), here, cycle.id, %{ends_on: ~D[2026-11-20]})
    assert has_element?(view, "#issue-cycle", "Nov 10 – Nov 20")

    render_patch(view, ~p"/testing/#{unplanned.id}")
    assert has_element?(view, "#issue-cycle", "No cycle")
  end

  test "an action on a ticket another tab already finished says so and changes nothing", %{
    conn: conn,
    done: done,
    here: here
  } do
    issue = done.(here, "Twice")
    {:ok, _noted} = Issues.save_testing_notes(system_scope(), issue, "Fine")
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    {:ok, _tested} = Issues.mark_issue_tested(system_scope(), issue)

    render_hook(view, "mark_tested", %{"issue_id" => issue.id})

    assert has_element?(view, "#testing-notice", "#{issue.identifier} was already marked tested.")
    assert has_element?(view, "#testing-notice", "Nothing was changed.")
    assert has_element?(view, "#testing-bar", issue.identifier)
    refute has_element?(view, "#testing-mark-tested")
    assert has_element?(view, "#testing-notes-status", "Testing finished")
    assert has_element?(view, "#testing-notes-#{issue.id}[readonly]")
    assert %Issue{testing_state: :tested, testing_notes: "Fine"} = Repo.get!(Issue, issue.id)

    render_hook(view, "save_notes", %{"issue_id" => issue.id, "notes" => "Too late"})
    assert has_element?(view, "#testing-notice", "was already marked tested.")
    assert %Issue{testing_notes: "Fine"} = Repo.get!(Issue, issue.id)
  end

  test "a send on a ticket already sent, or moved out of Done, says which", %{conn: conn, done: done, here: here} do
    sent = done.(here, "Sent elsewhere")
    reopened = done.(here, "Reopened elsewhere")
    {:ok, _noted} = Issues.save_testing_notes(system_scope(), sent, "Broken")
    {:ok, view, _html} = live(conn, ~p"/testing/#{sent.id}")
    {:ok, _created} = Issues.send_issue_to_triage(system_scope(), sent)

    render_hook(view, "send_to_triage", %{"issue_id" => sent.id})
    assert has_element?(view, "#testing-notice", "#{sent.identifier} was already sent to triage.")
    assert has_element?(view, "#testing-notes-status", "Testing finished")
    assert %{total: 1} = Issues.list_issues(project_id: sent.project_id, state: :todo)

    {:ok, view, _html} = live(conn, ~p"/testing/#{reopened.id}")

    {:ok, _canceled} =
      Issues.set_issue_status(system_scope(), reopened, %{id: "canceled", name: "Canceled", state: :canceled})

    refute has_element?(view, "#testing-bar-state")
    assert has_element?(view, "#testing-notes-status", "Not in Done")
    render_hook(view, "mark_tested", %{"issue_id" => reopened.id})
    assert has_element?(view, "#testing-notice", "#{reopened.identifier} is no longer in Done.")
  end

  test "Send to triage with blank notes asks for them", %{conn: conn, done: done, here: here} do
    issue = done.(here, "Blank")
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")

    render_hook(view, "send_to_triage", %{"issue_id" => issue.id})

    assert has_element?(view, "#testing-notice", "Write testing notes to send this to triage.")
    assert %Issue{testing_state: :waiting} = Repo.get!(Issue, issue.id)
  end

  test "a follow-up that cannot be filed names why and leaves the ticket in the queue", %{
    conn: conn,
    done: done,
    here: here
  } do
    issue = done.(here, "Refused")
    {:ok, _noted} = Issues.save_testing_notes(system_scope(), issue, "Broken")
    expect(Issues, :create_issue, fn _scope, _project, _attrs -> {:error, :db_down} end)

    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    view |> element("#testing-send-to-triage") |> render_click()

    assert has_element?(view, "#testing-notice", "That did not work: :db_down")
    assert has_element?(view, "#testing-row-#{issue.id} [data-testing-state='testing']")
  end

  test "the open ticket follows its comments, its changes and its blockers, and other news leaves it", %{
    conn: conn,
    done: done,
    here: here,
    there: there,
    user: user
  } do
    issue = done.(here, "Followed")
    test = self()

    stub(Issues, :get_blockers, fn [%Issue{id: id}] ->
      send(test, {:blockers_read, id})
      %{}
    end)

    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    render_async(view)
    assert_received {:blockers_read, _id}

    {:ok, _comment} = Issues.comment(Rail.Scope.for_user(user), issue, %{body: "Left after opening"})
    assert has_element?(view, "#issue-comments", "Left after opening")

    send(view.pid, {:issue_comments_changed, "iss_other"})
    send(view.pid, {:testing_notes_changed, "iss_other"})
    send(view.pid, {:nav_something, "unrelated"})
    unrelated = done.(there, "Unrelated")
    assert has_element?(view, "#testing-row-#{unrelated.id}")
    render_async(view)
    refute_received {:blockers_read, _id}

    issue |> Issue.tracker_changeset(%{title: "Renamed elsewhere"}) |> Repo.update!()
    Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, issue.id})
    render_async(view)
    assert has_element?(view, "#issue-title", "Renamed elsewhere")
    assert_received {:blockers_read, _id}

    {:ok, blocker} = Issues.create_issue(system_scope(), here, %{title: "Blocks the open ticket"})
    {:ok, bystander} = Issues.create_issue(system_scope(), here, %{title: "Blocked elsewhere"})
    render_async(view)
    refute_received {:blockers_read, _id}

    :ok = Issues.block_issue(system_scope(), blocker, bystander)
    render_async(view)
    refute_received {:blockers_read, _id}

    :ok = Issues.block_issue(system_scope(), blocker, issue)
    render_async(view)
    assert_received {:blockers_read, _id}
  end

  test "a page with nothing open opens the first ticket that arrives", %{
    conn: conn,
    done: done,
    here: here
  } do
    {:ok, view, _html} = live(conn, ~p"/testing")
    refute has_element?(view, "#testing-bar")

    issue = done.(here, "Arrived")
    assert has_element?(view, "#testing-bar", issue.identifier)
  end

  test "a blocker read that fails leaves the ticket without blocker sections", %{conn: conn, done: done, here: here} do
    issue = done.(here, "Blockers down")
    stub(Issues, :get_blockers, fn _issues -> raise "The blockers are down" end)

    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    render_async(view)

    assert has_element?(view, "#issue-title", "Blockers down")
    refute has_element?(view, "#issue-blocked-by")
  end
end
