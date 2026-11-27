defmodule RailWeb.TestingLiveTest do
  use RailWeb.ConnCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Rail.Issues
  alias Rail.Issues.Clients.R2
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.TestingImage
  alias Rail.Issues.Schemas.TestingScenario
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

    # The agent's scenarios, written as its pass writes them, so the ticket stays Waiting.
    written = fn issue, scenarios ->
      issue |> Issue.testing_scenarios_changeset(scenarios, :agent) |> Repo.update!()
    end

    %{
      conn: log_in_user(conn, user),
      here: here,
      there: there,
      hidden: hidden,
      done: done,
      written: written,
      user: user
    }
  end

  test "a role without the Testing tab is sent to its own first tab", %{conn: conn} do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "testing_live_role_#{id}",
        login: "testing_live-role-#{id}",
        email: "testing_live_role_#{id}@example.com"
      })

    for {role, home} <- [support: "/support"] do
      {:ok, user} = Users.update_user(system_scope(), user, %{role: role})

      assert {:error, {:redirect, %{to: ^home}}} = live(log_in_user(conn, user), ~p"/testing")
    end
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

  test "a ticket reopened before it was tested comes back with its scenarios, and a Tested one stays out", %{
    conn: conn,
    done: done,
    here: here
  } do
    in_progress = %{id: "in_progress", name: "In Progress", state: :in_progress}
    halfway = done.(here, "Reopened halfway")
    tested = done.(here, "Reopened after testing")
    {:ok, halfway} = Issues.add_testing_scenario(system_scope(), halfway, "Halfway")
    {:ok, tested} = Issues.mark_issue_tested(system_scope(), tested, %{no_scenarios_reason: "Only docs"})
    {:ok, view, _html} = live(conn, ~p"/testing")
    assert has_element?(view, "#testing-row-#{halfway.id}")
    refute has_element?(view, "#testing-row-#{tested.id}")

    {:ok, reopened} = Issues.set_issue_status(system_scope(), halfway, in_progress)
    refute has_element?(view, "#testing-row-#{halfway.id}")

    {:ok, _done} = Issues.set_issue_status(system_scope(), reopened, @done)
    assert has_element?(view, "#testing-row-#{halfway.id} [data-testing-state='testing']")

    view |> element("#testing-row-#{halfway.id}") |> render_click()
    assert has_element?(view, "#testing-scenario-list", "Halfway")

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

  test "the open ticket shows what its issue page shows, with nothing to change but its testing", %{
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
    assert [] = view |> element("#testing-ticket") |> render() |> Floki.parse_fragment!() |> Floki.find("textarea")

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

  test "marking a scenario saves at once, moves the ticket to In testing, and reads the same after a reload and in another tab",
       %{conn: conn, done: done, here: here, written: written} do
    issue = done.(here, "Marked")
    other = done.(here, "Untouched")
    %TestingScenario{id: first_id} = first = TestingScenario.agent("Six icons fit on the row")
    second = TestingScenario.agent("Seven wrap")
    written.(issue, [first, second])
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    {:ok, other_tab, _html} = live(conn, ~p"/testing/#{issue.id}")

    assert has_element?(view, "#testing-bar-state[data-testing-state='waiting']")
    assert has_element?(view, "#testing-scenario-#{first_id}-agent", "From the issue")
    assert has_element?(view, "#testing-scenario-#{first_id}", "1")
    assert has_element?(view, "#testing-progress", "0 passed")
    assert has_element?(view, "#testing-mark-tested[disabled][title='Mark tested is for when every scenario passed']")
    assert has_element?(view, "#testing-send-to-triage[disabled][title='Mark a scenario Failed to send this to triage']")

    view |> element("#testing-scenario-#{first_id}-passed") |> render_click()

    assert %Issue{testing_state: :testing, testing_scenarios: [%{result: :passed}, %{result: nil}]} =
             Repo.get!(Issue, issue.id)

    assert has_element?(view, "#testing-scenario-#{first_id}[data-result='passed']")
    assert has_element?(view, "#testing-scenario-#{first_id}-passed[aria-pressed='true']")
    assert has_element?(view, "#testing-progress", "1 passed")
    assert has_element?(view, "#testing-progress", "1 left")
    assert has_element?(view, "#testing-bar-state[data-testing-state='testing']")
    assert has_element?(view, "#testing-row-#{issue.id} [data-testing-state='testing']")
    assert has_element?(view, "#testing-queue-split", "1 waiting · 1 in testing")
    assert has_element?(other_tab, "#testing-scenario-#{first_id}[data-result='passed']")

    {:ok, again, _html} = live(conn, ~p"/testing/#{issue.id}")
    assert has_element?(again, "#testing-scenario-#{first_id}[data-result='passed']")
    assert %Issue{testing_state: :waiting} = Repo.get!(Issue, other.id)
  end

  test "a Failed scenario shows a note box and Attach pictures, saved as they change, and a Passed one shows neither",
       %{conn: conn, done: done, here: here, written: written} do
    issue = done.(here, "Noted")
    %TestingScenario{id: scenario_id} = scenario = TestingScenario.agent("The row fits")
    written.(issue, [scenario])
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")

    refute has_element?(view, "#testing-note-#{scenario_id}")
    refute has_element?(view, "#testing-scenario-#{scenario_id}-attach")

    view |> element("#testing-scenario-#{scenario_id}-failed") |> render_click()
    assert has_element?(view, "#testing-note-#{scenario_id}")
    assert has_element?(view, "#testing-scenario-#{scenario_id}-attach", "Attach pictures")
    refute has_element?(view, "#testing-send-to-triage[disabled]")

    view
    |> form("#testing-form-#{issue.id}")
    |> render_change(%{"_target" => ["notes", scenario_id], "notes" => %{scenario_id => "Cut off at 1280"}})

    assert %Issue{testing_scenarios: [%{result: :failed, note: "Cut off at 1280"}]} = Repo.get!(Issue, issue.id)

    view |> element("#testing-scenario-#{scenario_id}-passed") |> render_click()
    refute has_element?(view, "#testing-note-#{scenario_id}")
    assert %Issue{testing_scenarios: [%{result: :passed, note: "Cut off at 1280"}]} = Repo.get!(Issue, issue.id)

    view |> element("#testing-scenario-#{scenario_id}-failed") |> render_click()
    assert has_element?(view, "#testing-note-#{scenario_id}", "Cut off at 1280")
  end

  test "a tester's scenario goes at the end with no label, and any scenario can be removed", %{
    conn: conn,
    done: done,
    here: here,
    written: written
  } do
    issue = done.(here, "Listed")
    %TestingScenario{id: agent_id} = agent = TestingScenario.agent("From the agent")
    written.(issue, [agent])
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")

    view |> form("#testing-add-scenario-#{issue.id}-0", %{title: "  Mine  "}) |> render_submit()

    assert %Issue{testing_state: :testing, testing_scenarios: [%{id: ^agent_id}, %{id: own_id, title: "Mine"}]} =
             Repo.get!(Issue, issue.id)

    assert has_element?(view, "#testing-scenario-#{own_id}", "Mine")
    refute has_element?(view, "#testing-scenario-#{own_id}-agent")
    assert has_element?(view, "#testing-add-scenario-#{issue.id}-1 #testing-new-scenario")

    view |> form("#testing-add-scenario-#{issue.id}-1", %{title: "   "}) |> render_submit()
    assert %Issue{testing_scenarios: [_agent, _own]} = Repo.get!(Issue, issue.id)

    view |> element("#testing-scenario-#{agent_id}-remove") |> render_click()
    refute has_element?(view, "#testing-scenario-#{agent_id}")
    assert %Issue{testing_scenarios: [%{title: "Mine"}]} = Repo.get!(Issue, issue.id)

    view |> element("#testing-scenario-#{own_id}-remove") |> render_click()
    assert has_element?(view, "#testing-scenarios-empty", "No scenarios yet. Add the ones you want to check.")
  end

  test "Where I tested offers Production and Staging, a platform and a device, and keeps them over a reload", %{
    conn: conn,
    done: done,
    here: here
  } do
    issue = done.(here, "Placed")
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")

    assert has_element?(view, "#testing-environment-production", "Production")
    assert has_element?(view, "#testing-environment-staging", "Staging")
    refute has_element?(view, "#testing-environment", "Preview")

    view |> element("#testing-environment-staging") |> render_click()
    view |> element("#testing-platform-ios") |> render_click()

    view
    |> form("#testing-form-#{issue.id}")
    |> render_change(%{"_target" => ["testing_device"], "testing_device" => "iPhone 15"})

    assert %Issue{
             testing_state: :testing,
             testing_environment: :staging,
             testing_platform: :ios,
             testing_device: "iPhone 15"
           } =
             Repo.get!(Issue, issue.id)

    {:ok, again, _html} = live(conn, ~p"/testing/#{issue.id}")
    assert has_element?(again, "#testing-environment-staging[aria-pressed='true']")
    assert has_element?(again, "#testing-platform-ios[aria-pressed='true']")
    assert has_element?(again, "#testing-device[value='iPhone 15']")
  end

  test "a picture goes to the failed scenario it was started on, shows there once stored, and comes out on remove", %{
    conn: conn,
    done: done,
    here: here,
    written: written
  } do
    issue = done.(here, "Pictured")
    %TestingScenario{id: first_id} = first = %{TestingScenario.agent("First") | result: :failed}
    %TestingScenario{id: second_id} = second = %{TestingScenario.agent("Second") | result: :failed}
    written.(issue, [first, second])
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    form = "#testing-form-#{issue.id}"

    Req.Test.expect(R2, fn r2 ->
      assert ["image/png"] = Plug.Conn.get_req_header(r2, "content-type")
      Plug.Conn.send_resp(r2, 200, "")
    end)

    view |> element("#testing-note-#{first_id}") |> render_focus()

    shot =
      file_input(view, form, :testing_images, [%{name: "row.png", content: :binary.copy("P", 1000), type: "image/png"}])

    # The browser sends the form's change once the upload is allowed, before the rest of it.
    render_upload(shot, "row.png", 1)
    view |> element(form) |> render_change(%{"_target" => ["testing_images"]})
    render_upload(shot, "row.png", 49)
    assert has_element?(view, "#testing-scenario-#{first_id} [id^='testing-upload-'][title='row.png']")

    # Focusing another note mid-upload moves neither the picture nor its chip.
    view |> element("#testing-note-#{second_id}") |> render_focus()
    refute has_element?(view, "#testing-scenario-#{second_id} [id^='testing-upload-']")
    render_upload(shot, "row.png", 50)
    render_async(view)

    assert %Issue{
             testing_state: :testing,
             testing_scenarios: [%{images: [%TestingImage{name: "row.png", url: url}]}, %{images: []}]
           } = Repo.get!(Issue, issue.id)

    assert has_element?(view, "#testing-scenario-#{first_id}-image-0[title='row.png'] img[src='#{url}']")
    refute has_element?(view, "[id^='testing-upload-']")

    view |> element("#testing-scenario-#{first_id}-image-0 [data-qa='image-chip-remove']") |> render_click()

    refute has_element?(view, "#testing-scenario-#{first_id}-image-0")
    assert %Issue{testing_scenarios: [%{images: []}, _second]} = Repo.get!(Issue, issue.id)
  end

  test "Attach pictures names its scenario, and a picture started on no scenario is not added", %{
    conn: conn,
    done: done,
    here: here,
    written: written
  } do
    issue = done.(here, "Attached")
    %TestingScenario{id: scenario_id} = scenario = %{TestingScenario.agent("First") | result: :failed}
    written.(issue, [scenario])
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    form = "#testing-form-#{issue.id}"

    lost =
      file_input(view, form, :testing_images, [%{name: "lost.png", content: :binary.copy("P", 1000), type: "image/png"}])

    render_upload(lost, "lost.png", 1)
    view |> element(form) |> render_change(%{"_target" => ["testing_images"]})
    render_upload(lost, "lost.png", 99)
    assert has_element?(view, "#testing-image-error", "Couldn't add lost.png. Try adding it again.")

    Req.Test.expect(R2, &Plug.Conn.send_resp(&1, 200, ""))
    view |> element("#testing-scenario-#{scenario_id}-attach") |> render_click()

    shot =
      file_input(view, form, :testing_images, [%{name: "kept.png", content: :binary.copy("P", 1000), type: "image/png"}])

    render_upload(shot, "kept.png", 1)
    view |> element(form) |> render_change(%{"_target" => ["testing_images"]})
    render_upload(shot, "kept.png", 99)
    render_async(view)

    assert %Issue{testing_scenarios: [%{images: [%TestingImage{name: "kept.png"}]}]} = Repo.get!(Issue, issue.id)
    refute has_element?(view, "#testing-image-error")
  end

  test "a file the box cannot take says why and is not kept", %{
    conn: conn,
    done: done,
    here: here
  } do
    issue = done.(here, "Refused")
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    form = "#testing-form-#{issue.id}"

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
    form = "#testing-form-#{issue.id}"

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

  test "a picture R2 fails to store, or one for a ticket finished or being written meanwhile, says so", %{
    conn: conn,
    done: done,
    here: here,
    written: written
  } do
    issue = done.(here, "Failing")
    %TestingScenario{id: scenario_id} = scenario = %{TestingScenario.agent("First") | result: :failed}
    written.(issue, [scenario])
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    form = "#testing-form-#{issue.id}"
    view |> element("#testing-note-#{scenario_id}") |> render_focus()

    upload = fn name ->
      shot = file_input(view, form, :testing_images, [%{name: name, content: :binary.copy("P", 1000), type: "image/png"}])
      render_upload(shot, name, 1)
      view |> element(form) |> render_change(%{"_target" => ["testing_images"]})
      render_upload(shot, name, 99)
      render_async(view)
    end

    Req.Test.expect(R2, &Plug.Conn.send_resp(&1, 500, "down"))
    upload.("a.png")
    assert has_element?(view, "#testing-image-error", "Couldn't add a.png. Try adding it again.")

    Req.Test.expect(R2, fn r2 ->
      {:ok, _requested} = Issues.request_test_scenarios(issue, "3c9a1f0e2b")
      Plug.Conn.send_resp(r2, 200, "")
    end)

    upload.("b.png")
    assert has_element?(view, "#testing-image-error", "b.png was not added: Rail is still writing scenarios.")

    Repo.update_all(from(i in Issue, where: i.id == ^issue.id), set: [scenarios_requested_at: nil])
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    view |> element("#testing-note-#{scenario_id}") |> render_focus()

    Req.Test.expect(R2, fn r2 ->
      {:ok, _sent} = Issues.send_issue_to_triage(system_scope(), issue)
      Plug.Conn.send_resp(r2, 200, "")
    end)

    shot =
      file_input(view, form, :testing_images, [%{name: "c.png", content: :binary.copy("P", 1000), type: "image/png"}])

    render_upload(shot, "c.png", 1)
    view |> element(form) |> render_change(%{"_target" => ["testing_images"]})
    render_upload(shot, "c.png", 99)
    render_async(view)
    assert has_element?(view, "#testing-image-error", "c.png was not added: testing on this ticket has finished.")
  end

  test "removing a picture from a ticket finished in another tab says so", %{
    conn: conn,
    done: done,
    here: here,
    written: written
  } do
    issue = done.(here, "Finished elsewhere")

    %TestingScenario{id: scenario_id} =
      scenario =
      %{TestingScenario.agent("First") | result: :failed, images: [%TestingImage{url: "https://x/a.png", name: "a.png"}]}

    written.(issue, [scenario])
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    {:ok, _sent} = Issues.send_issue_to_triage(system_scope(), issue)

    # The finished ticket's page drops the button, so this is a click sent before it did.
    render_click(view, "remove_testing_image", %{
      "issue_id" => issue.id,
      "scenario_id" => scenario_id,
      "url" => "https://x/a.png"
    })

    assert has_element?(view, "#testing-notice", "was already sent to triage")
    assert %Issue{testing_scenarios: [%{images: [%TestingImage{name: "a.png"}]}]} = Repo.get!(Issue, issue.id)
  end

  test "a finished ticket shows its scenarios, notes and pictures read-only, with nothing to press", %{
    conn: conn,
    done: done,
    here: here,
    written: written
  } do
    issue = done.(here, "Pictured")

    %TestingScenario{id: failed_id} =
      failed =
      %{
        TestingScenario.agent("First")
        | result: :failed,
          note: "Cut off",
          images: [%TestingImage{url: "https://x/a/b/shot.png", name: "shot.png"}]
      }

    %TestingScenario{id: passed_id} = passed = %{TestingScenario.agent("Second") | result: :passed}
    written.(issue, [failed, passed])

    {:ok, _placed} = Issues.save_testing_place(system_scope(), issue, %{testing_device: "Pixel 8"})
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    assert has_element?(view, "#testing-scenario-#{failed_id}-image-0 img[src='https://x/a/b/shot.png']")
    assert has_element?(view, "#testing-scenario-#{failed_id}-image-0 [data-qa='image-chip-remove']")

    {:ok, _sent} = Issues.send_issue_to_triage(system_scope(), issue)
    {:ok, finished, _html} = live(conn, ~p"/testing/#{issue.id}")

    assert has_element?(finished, "#testing-lock", "Testing finished")
    assert has_element?(finished, "#testing-scenario-#{failed_id}-note", "Cut off")
    assert has_element?(finished, "#testing-scenario-#{failed_id}-image-0")
    refute has_element?(finished, "#testing-scenario-#{failed_id}-image-0 [data-qa='image-chip-remove']")
    refute has_element?(finished, "#testing-note-#{failed_id}")
    refute has_element?(finished, "#testing-scenario-#{failed_id}-remove")
    assert has_element?(finished, "#testing-scenario-#{passed_id}-passed[disabled]")
    assert has_element?(finished, "#testing-environment-staging[disabled]")
    assert has_element?(finished, "#testing-device-text", "Pixel 8")
    refute has_element?(finished, "#testing-device")
    refute has_element?(finished, "#testing-add-scenario-#{issue.id}-0")
    refute has_element?(finished, "#testing-scenarios-empty")
    refute has_element?(finished, "#testing-progress")
    refute has_element?(finished, "input[type='file']")
  end

  test "notes and pictures from before scenarios show read-only above the list", %{conn: conn, done: done, here: here} do
    issue = done.(here, "Noted before")

    Repo.update_all(from(i in Issue, where: i.id == ^issue.id),
      set: [
        testing_notes: "Checked on staging",
        testing_images: [%TestingImage{url: "https://x/old.png", name: "old.png"}]
      ]
    )

    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")

    assert has_element?(view, "#testing-earlier-notes", "Notes from before scenarios")
    assert has_element?(view, "#testing-earlier-notes", "Checked on staging")
    assert has_element?(view, "#testing-earlier-image-0 img[src='https://x/old.png']")
    refute has_element?(view, "#testing-earlier-image-0 [data-qa='image-chip-remove']")

    assert has_element?(
             view,
             "#testing-earlier-notes",
             "With no scenarios, Mark tested asks why there was nothing to test."
           )

    {:ok, plain, _html} = live(conn, ~p"/testing/#{done.(here, "Nothing before").id}")
    refute has_element?(plain, "#testing-earlier-notes")
  end

  test "opening a ticket without typing leaves it Waiting", %{conn: conn, done: done, here: here} do
    issue = done.(here, "Only looked")
    {:ok, _view, _html} = live(conn, ~p"/testing/#{issue.id}")
    assert %Issue{testing_state: :waiting, testing_scenarios: []} = Repo.get!(Issue, issue.id)
  end

  test "a mark another tab saves shows on an open page, and a note flushed after a switch goes to its own ticket", %{
    conn: conn,
    done: done,
    here: here,
    written: written
  } do
    issue = done.(here, "Shared")
    other = done.(here, "Switched to")
    %TestingScenario{id: shared_id} = shared = TestingScenario.agent("Shared")
    %TestingScenario{id: other_id} = other_scenario = %{TestingScenario.agent("Elsewhere") | result: :failed}
    written.(issue, [shared])
    written.(other, [other_scenario])
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")

    {:ok, _saved} = Issues.save_testing_scenario(system_scope(), issue, shared_id, %{result: "failed"})
    assert has_element?(view, "#testing-scenario-#{shared_id}[data-result='failed']")

    render_hook(view, "save_testing", %{
      "_target" => ["notes", other_id],
      "issue_id" => other.id,
      "notes" => %{other_id => "Typed before switching"}
    })

    assert %Issue{testing_scenarios: [%{note: "Typed before switching"}]} = Repo.get!(Issue, other.id)
    assert has_element?(view, "#testing-bar", issue.identifier)

    render_hook(view, "save_testing", %{
      "_target" => ["notes", shared_id],
      "issue_id" => "iss_elsewhere",
      "notes" => %{shared_id => "Lost"}
    })

    assert has_element?(view, "#testing-bar", issue.identifier)
    assert %Issue{testing_scenarios: [%{note: nil}]} = Repo.get!(Issue, issue.id)
  end

  test "form recovery that names the upload with no pictures, or a disabled device, saves nothing", %{
    conn: conn,
    done: done,
    here: here
  } do
    issue = done.(here, "Recovered")
    {:ok, _requested} = Issues.request_test_scenarios(issue, "3c9a1f0e2b")
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")

    render_hook(view, "save_testing", %{"_target" => ["testing_images"], "issue_id" => issue.id})
    render_hook(view, "save_testing", %{"_target" => ["testing_device"], "issue_id" => issue.id})

    refute has_element?(view, "#testing-notice")
    refute has_element?(view, "#testing-image-error")
    assert %Issue{testing_device: nil, testing_state: :waiting} = Repo.get!(Issue, issue.id)
  end

  test "Mark tested opens the next ticket, and the last one leaves the queue empty", %{
    conn: conn,
    done: done,
    here: here,
    written: written
  } do
    first = done.(here, "First")
    second = done.(here, "Second")
    written.(second, [%{TestingScenario.agent("Passed") | result: :passed}])
    {:ok, view, _html} = live(conn, ~p"/testing/#{second.id}")

    view |> element("#testing-mark-tested") |> render_click()

    assert_patch(view, ~p"/testing/#{first.id}", 1_000)
    assert %Issue{state: :done, testing_state: :tested} = Repo.get!(Issue, second.id)
    refute has_element?(view, "#testing-row-#{second.id}")
    refute has_element?(view, "#testing-notice")

    view |> element("#testing-mark-tested") |> render_click()
    view |> form("#tested-reason-dialog", %{no_scenarios_reason: "Only docs"}) |> render_submit()

    assert_patch(view, ~p"/testing", 1_000)
    assert has_element?(view, "#testing-queue-empty")
    refute has_element?(view, "#testing-bar")
    refute has_element?(view, "#tested-reason-dialog")
  end

  test "Mark tested on an empty list asks why, refuses a blank answer, and keeps the reason it is given", %{
    conn: conn,
    done: done,
    here: here
  } do
    issue = done.(here, "Docs only")
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")

    assert has_element?(view, "#testing-scenarios-empty", "No scenarios yet. Add the ones you want to check.")
    assert has_element?(view, "#testing-scenarios-empty", "Mark tested asks why there was nothing to test.")
    refute has_element?(view, "#testing-mark-tested[disabled]")

    view |> element("#testing-mark-tested") |> render_click()
    assert has_element?(view, "#tested-reason-title", "Mark #{issue.identifier} tested with no scenarios")

    view |> element("#tested-reason-cancel") |> render_click()
    refute has_element?(view, "#tested-reason-dialog")

    view |> element("#testing-mark-tested") |> render_click()
    render_keydown(view, "close_tested_reason", %{"key" => "Escape"})
    refute has_element?(view, "#tested-reason-dialog")

    view |> element("#testing-mark-tested") |> render_click()
    view |> form("#tested-reason-dialog", %{no_scenarios_reason: "   "}) |> render_submit()

    assert has_element?(view, "#tested-reason-error", "Write why there was nothing to test.")
    assert %Issue{testing_state: :waiting, no_scenarios_reason: nil} = Repo.get!(Issue, issue.id)

    view |> form("#tested-reason-dialog", %{no_scenarios_reason: " No tests, it was only docs "}) |> render_submit()

    assert_patch(view, ~p"/testing", 1_000)
    assert %Issue{testing_state: :tested, no_scenarios_reason: "No tests, it was only docs"} = Repo.get!(Issue, issue.id)

    {:ok, tested, _html} = live(conn, ~p"/testing/#{issue.id}")
    assert has_element?(tested, "#testing-no-scenarios-reason", "Marked tested with no scenarios")
    assert has_element?(tested, "#testing-no-scenarios-reason", "No tests, it was only docs")
    refute has_element?(tested, "#testing-scenarios-empty")
  end

  test "Mark tested on a ticket another tab marked shows the notice, not the dialog", %{
    conn: conn,
    done: done,
    here: here
  } do
    issue = done.(here, "Marked elsewhere")
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    {:ok, _tested} = Issues.mark_issue_tested(system_scope(), issue, %{no_scenarios_reason: "Docs"})

    render_click(view, "mark_tested", %{"issue_id" => issue.id})

    assert has_element?(view, "#testing-notice", "#{issue.identifier} was already marked tested.")
    refute has_element?(view, "#tested-reason-dialog")
  end

  test "the reason dialog closes on a refusal and shows its notice, and opens when the last scenario went elsewhere", %{
    conn: conn,
    done: done,
    here: here,
    written: written
  } do
    issue = done.(here, "Changed meanwhile")
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    view |> element("#testing-mark-tested") |> render_click()
    {:ok, %Issue{testing_scenarios: [%{id: added_id}]}} = Issues.add_testing_scenario(system_scope(), issue, "Added")

    view |> form("#tested-reason-dialog", %{no_scenarios_reason: "Docs"}) |> render_submit()

    refute has_element?(view, "#tested-reason-dialog")
    assert has_element?(view, "#testing-notice", "Mark tested is for when every scenario passed.")

    {:ok, _passed} = Issues.save_testing_scenario(system_scope(), issue, added_id, %{result: "passed"})
    other = done.(here, "Emptied meanwhile")
    other = written.(other, [%{TestingScenario.agent("Passed") | result: :passed}])
    {:ok, view, _html} = live(conn, ~p"/testing/#{other.id}")
    # Emptied with no broadcast, so the page still shows the scenario it had.
    other |> Issue.testing_scenarios_changeset([], :agent) |> Repo.update!()

    view |> element("#testing-mark-tested") |> render_click()
    assert has_element?(view, "#tested-reason-error", "Write why there was nothing to test.")
    assert %Issue{testing_state: :waiting} = Repo.get!(Issue, other.id)
  end

  test "a ticket being written waits on the agent, takes its scenarios when the pass ends, and opens after two hours", %{
    conn: conn,
    done: done,
    here: here
  } do
    issue = done.(here, "Just merged")

    {:ok, _qa} =
      Rail.Roles.create_role(system_scope(), here, %{
        stage: :qa,
        name: "QA",
        model: "claude-opus-5-5",
        system_prompt: "You test.",
        cli: :claude
      })

    {:ok, _requested} = Issues.request_test_scenarios(issue, "3c9a1f0e2b")
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    {:ok, other_tab, _html} = live(conn, ~p"/testing/#{issue.id}")

    assert has_element?(view, "#testing-writing", "Writing scenarios…")
    assert has_element?(view, "#testing-writing", "An agent is reading #{issue.identifier} and its merged pull request.")
    assert has_element?(view, "#testing-mark-tested[disabled][title='Rail is writing scenarios for this ticket']")
    assert has_element?(view, "#testing-send-to-triage[disabled][title='Rail is writing scenarios for this ticket']")
    assert has_element?(view, "#testing-environment-staging[disabled]")
    assert has_element?(view, "#testing-device[disabled]")
    assert has_element?(view, "#testing-new-scenario[disabled]")
    refute has_element?(view, "#testing-scenarios-empty")
    refute has_element?(view, "input[type='file']")

    render_click(view, "mark_scenario", %{"issue_id" => issue.id, "scenario_id" => "tsc_x", "result" => "passed"})

    assert has_element?(
             view,
             "#testing-notice",
             "Rail is still writing scenarios for #{issue.identifier}. Nothing was changed."
           )

    render_click(view, "mark_tested", %{"issue_id" => issue.id})
    refute has_element?(view, "#tested-reason-dialog")

    expect(Rail.Tools, :run_agent, fn _role, _argv, opts ->
      claimed = Repo.get!(Issue, issue.id).scenarios_started_at
      dir = Path.join([Rail.scratch_root(), issue.project_id, "testing", "#{issue.id}-#{DateTime.to_unix(claimed)}"])
      File.write!(Path.join(dir, "result.json"), ~s({"scenarios": ["Open the export"]}))
      {:ok, opts[:cd]}
    end)

    stub(Rail.Git, :checkout_detached_worktree, fn _project, path -> {:ok, path} end)
    stub(Rail.Git, :remove_worktree, fn _clone, _path -> :ok end)
    assert :ok = Issues.write_test_scenarios(issue, "3c9a1f0e2b")

    for tab <- [view, other_tab] do
      refute has_element?(tab, "#testing-writing")
      assert has_element?(tab, "#testing-scenario-list", "Open the export")
      assert has_element?(tab, "[id$='-agent']", "From the issue")
    end

    stalled = done.(here, "Pass died")
    {:ok, _requested} = Issues.request_test_scenarios(stalled, "4d0b2e1f3c")
    {:ok, view, _html} = live(conn, ~p"/testing/#{stalled.id}")
    assert has_element?(view, "#testing-writing")

    expired = DateTime.utc_now() |> DateTime.shift(minute: -121) |> DateTime.truncate(:second)
    Repo.update_all(from(i in Issue, where: i.id == ^stalled.id), set: [scenarios_requested_at: expired])
    send(view.pid, {:writing_ended, "iss_other"})
    assert has_element?(view, "#testing-writing")

    send(view.pid, {:writing_ended, stalled.id})
    refute has_element?(view, "#testing-writing")
    assert has_element?(view, "#testing-scenarios-empty", "No scenarios yet. Add the ones you want to check.")
    refute has_element?(view, "#testing-mark-tested[disabled]")
  end

  test "moving between two tickets being written keeps one timer, for the ticket shown", %{
    conn: conn,
    done: done,
    here: here
  } do
    first = done.(here, "First merged")
    second = done.(here, "Second merged")
    {:ok, _requested} = Issues.request_test_scenarios(first, "3c9a1f0e2b")
    {:ok, _requested} = Issues.request_test_scenarios(second, "4d0b2e1f3c")
    {:ok, view, _html} = live(conn, ~p"/testing/#{first.id}")

    view |> element("#testing-row-#{second.id}") |> render_click()
    assert has_element?(view, "#testing-bar", second.identifier)
    assert has_element?(view, "#testing-writing")

    # The first ticket's timer was cancelled, so only the shown ticket's message would ever arrive.
    send(view.pid, {:writing_ended, first.id})
    assert has_element?(view, "#testing-writing")
  end

  test "a second click meant for a ticket the page has moved on from does nothing", %{
    conn: conn,
    done: done,
    here: here,
    written: written
  } do
    first = done.(here, "First")
    second = done.(here, "Second")
    written.(first, [%{TestingScenario.agent("Passed") | result: :passed}])
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
    here: here,
    written: written
  } do
    sent = done.(here, "Broken")
    next = done.(here, "Next")
    %TestingScenario{id: scenario_id} = scenario = TestingScenario.agent("The row fits")
    written.(sent, [scenario])
    {:ok, view, _html} = live(conn, ~p"/testing/#{sent.id}")

    view |> element("#testing-scenario-#{scenario_id}-failed") |> render_click()

    view
    |> form("#testing-form-#{sent.id}")
    |> render_change(%{"_target" => ["notes", scenario_id], "notes" => %{scenario_id => "The row is cut off"}})

    view |> element("#testing-send-to-triage") |> render_click()

    assert_patch(view, ~p"/testing/#{next.id}", 1_000)
    assert %Issue{state: :done, testing_state: :sent_to_triage} = Repo.get!(Issue, sent.id)

    assert %{issues: [%Issue{identifier: created, description: description}]} =
             Issues.list_issues(project_id: here.id, state: :todo)

    assert description =~ "- Failed: The row fits"
    assert description =~ "1. The row fits\n\n   The row is cut off"

    assert has_element?(view, "#testing-notice", "#{sent.identifier} sent to triage as #{created}.")
    assert has_element?(view, "#testing-notice-created[href='/issues/#{created}']")

    view |> element("#testing-row-#{next.id}") |> render_click()
    assert has_element?(view, "#testing-notice")

    view |> element("#testing-mark-tested") |> render_click()
    view |> form("#tested-reason-dialog", %{no_scenarios_reason: "Only docs"}) |> render_submit()
    assert_patch(view, ~p"/testing", 1_000)
    refute has_element?(view, "#testing-notice")
  end

  test "Send to triage on the last ticket keeps its notice over the empty queue", %{
    conn: conn,
    done: done,
    here: here,
    written: written
  } do
    sent = done.(here, "Last")
    written.(sent, [%{TestingScenario.agent("Broken") | result: :failed}])
    {:ok, view, _html} = live(conn, ~p"/testing")

    view |> element("#testing-send-to-triage") |> render_click()

    assert has_element?(view, "#testing-advancing", "Updating the queue...")
    assert_patch(view, ~p"/testing", 1_000)
    assert has_element?(view, "#testing-notice", "sent to triage as")
    assert has_element?(view, "#testing-queue-empty")
  end

  test "a finished action shows a loading screen that ignores a second click", %{
    conn: conn,
    done: done,
    here: here,
    written: written
  } do
    first = done.(here, "First")
    second = done.(here, "Second")
    third = done.(here, "Third")
    written.(first, [%{TestingScenario.agent("Broken") | result: :failed}])
    written.(second, [%{TestingScenario.agent("Fine") | result: :passed}])
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
    here: here,
    written: written
  } do
    first = done.(here, "First")
    _second = done.(here, "Second")
    third = done.(here, "Third")
    written.(first, [%{TestingScenario.agent("Fine") | result: :passed}])
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

  test "leaving a note shows the note saved last", %{conn: conn, done: done, here: here, written: written} do
    issue = done.(here, "Two testers")
    %TestingScenario{id: scenario_id} = scenario = %{TestingScenario.agent("Shared") | result: :failed}
    written.(issue, [scenario])
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")

    view
    |> form("#testing-form-#{issue.id}")
    |> render_change(%{"_target" => ["notes", scenario_id], "notes" => %{scenario_id => "Mine"}})

    assert has_element?(view, "#testing-note-#{scenario_id}[data-rev='0']")
    {:ok, _theirs} = Issues.save_testing_scenario(system_scope(), issue, scenario_id, %{note: "Theirs, saved last"})

    view |> element("#testing-note-#{scenario_id}") |> render_blur()

    assert has_element?(view, "#testing-note-#{scenario_id}[data-rev='1']", "Theirs, saved last")
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
    here: here,
    written: written
  } do
    issue = done.(here, "Twice")
    %TestingScenario{id: scenario_id} = scenario = %{TestingScenario.agent("Fine") | result: :passed}
    written.(issue, [scenario])
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")
    {:ok, _tested} = Issues.mark_issue_tested(system_scope(), issue, %{})

    render_hook(view, "mark_tested", %{"issue_id" => issue.id})

    assert has_element?(view, "#testing-notice", "#{issue.identifier} was already marked tested.")
    assert has_element?(view, "#testing-notice", "Nothing was changed.")
    assert has_element?(view, "#testing-bar", issue.identifier)
    refute has_element?(view, "#testing-mark-tested")
    assert has_element?(view, "#testing-lock", "Testing finished")
    assert has_element?(view, "#testing-scenario-#{scenario_id}-failed[disabled]")
    assert %Issue{testing_state: :tested} = Repo.get!(Issue, issue.id)

    render_hook(view, "mark_scenario", %{"issue_id" => issue.id, "scenario_id" => scenario_id, "result" => "failed"})
    assert has_element?(view, "#testing-notice", "was already marked tested.")
    assert %Issue{testing_scenarios: [%{result: :passed}]} = Repo.get!(Issue, issue.id)
  end

  test "a send on a ticket already sent, or moved out of Done, says which", %{
    conn: conn,
    done: done,
    here: here,
    written: written
  } do
    sent = done.(here, "Sent elsewhere")
    reopened = done.(here, "Reopened elsewhere")
    written.(sent, [%{TestingScenario.agent("Broken") | result: :failed}])
    {:ok, view, _html} = live(conn, ~p"/testing/#{sent.id}")
    {:ok, _created} = Issues.send_issue_to_triage(system_scope(), sent)

    render_hook(view, "send_to_triage", %{"issue_id" => sent.id})
    assert has_element?(view, "#testing-notice", "#{sent.identifier} was already sent to triage.")
    assert has_element?(view, "#testing-lock", "Testing finished")
    assert %{total: 1} = Issues.list_issues(project_id: sent.project_id, state: :todo)

    {:ok, view, _html} = live(conn, ~p"/testing/#{reopened.id}")

    {:ok, _canceled} =
      Issues.set_issue_status(system_scope(), reopened, %{id: "canceled", name: "Canceled", state: :canceled})

    refute has_element?(view, "#testing-bar-state")
    assert has_element?(view, "#testing-lock", "Not in Done")
    render_hook(view, "mark_tested", %{"issue_id" => reopened.id})
    assert has_element?(view, "#testing-notice", "#{reopened.identifier} is no longer in Done.")
  end

  test "Send to triage with no failed scenario, and Mark tested with one open, each say what they need", %{
    conn: conn,
    done: done,
    here: here,
    written: written
  } do
    issue = done.(here, "Open")
    written.(issue, [TestingScenario.agent("Unmarked")])
    {:ok, view, _html} = live(conn, ~p"/testing/#{issue.id}")

    render_hook(view, "send_to_triage", %{"issue_id" => issue.id})
    assert has_element?(view, "#testing-notice", "Mark a scenario Failed to send this to triage.")

    render_hook(view, "mark_tested", %{"issue_id" => issue.id})
    assert has_element?(view, "#testing-notice", "Mark tested is for when every scenario passed.")
    assert %Issue{testing_state: :waiting} = Repo.get!(Issue, issue.id)
  end

  test "a follow-up that cannot be filed names why and leaves the ticket in the queue", %{
    conn: conn,
    done: done,
    here: here
  } do
    issue = done.(here, "Refused")
    {:ok, %Issue{testing_scenarios: [%{id: scenario_id}]}} = Issues.add_testing_scenario(system_scope(), issue, "Broken")
    {:ok, _failed} = Issues.save_testing_scenario(system_scope(), issue, scenario_id, %{result: "failed"})
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
    send(view.pid, {:testing_changed, "iss_other"})
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
