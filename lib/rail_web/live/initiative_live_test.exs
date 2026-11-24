defmodule RailWeb.InitiativeLiveTest do
  use RailWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Rail.Initiatives
  alias Rail.Initiatives.Schemas.Initiative
  alias Rail.Initiatives.Schemas.InitiativeComment
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Users

  @done %{id: "done", name: "Done", state: :done}
  @in_progress %{id: "in_progress", name: "In Progress", state: :in_progress}
  @canceled %{id: "canceled", name: "Canceled", state: :canceled}

  setup %{conn: conn} do
    key = "ILP#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Dishbooks",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_#{key}",
        login: "paulo_#{key}",
        name: "Paulo",
        email: "#{key}@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    stub(Date, :utc_today, fn -> ~D[2026-11-23] end)

    {:ok, initiative} =
      Initiatives.create_initiative(system_scope(), project, %{
        name: "Credo exclusions",
        expected_on: ~D[2026-12-12],
        notes: "### Plan\\n\\nTake every module off **the list**."
      })

    tickets =
      for {title, status} <- [{"Two API actions", @done}, {"Banks sync", @in_progress}, {"Reconciliation", nil}] do
        {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: title, owner_user_id: user.id})
        {:ok, issue} = Issues.set_issue_initiative(system_scope(), issue, initiative.id)
        if status, do: {:ok, _issue} = Issues.set_issue_status(system_scope(), issue, status)
        issue
      end

    %{conn: log_in_user(conn, user), user: user, local: project, key: key, initiative: initiative, tickets: tickets}
  end

  test "shows the notes, the tickets by status, progress, the expected date and the project", %{
    conn: conn,
    local: local,
    initiative: initiative,
    tickets: [done, started, todo]
  } do
    {:ok, canceled} = Issues.create_issue(system_scope(), local, %{title: "Split the job"})
    {:ok, canceled} = Issues.set_issue_initiative(system_scope(), canceled, initiative.id)
    {:ok, _issue} = Issues.set_issue_status(system_scope(), canceled, @canceled)

    {:ok, view, _html} = live(conn, ~p"/initiatives/#{initiative.id}")

    assert page_title(view) =~ "Credo exclusions"
    assert has_element?(view, "#nav-initiatives[data-active='true']")
    assert has_element?(view, "#initiative-breadcrumb[href='/initiatives']")
    assert has_element?(view, "#initiative-name", "Credo exclusions")
    assert has_element?(view, "#initiative-notes h3", "Plan")
    assert has_element?(view, "#initiative-notes strong", "the list")
    assert has_element?(view, "#initiative-ticket-total", "4")

    assert has_element?(view, "section[aria-label='Done'] #issue-card-#{done.id}", "Two API actions")
    assert has_element?(view, "section[aria-label='In Progress'] #issue-card-#{started.id}")
    assert has_element?(view, "section[aria-label='Todo'] #issue-card-#{todo.id}")
    assert has_element?(view, "section[aria-label='Canceled'] #issue-card-#{canceled.id}")
    assert has_element?(view, "section[aria-label='Canceled']", "not counted in progress")

    assert has_element?(view, "#initiative-percent", "33%")
    assert has_element?(view, "[role='progressbar'][aria-valuenow='33']")
    assert has_element?(view, "#initiative-counts", "1 of 3 tickets")
    assert has_element?(view, "#initiative-counts", "1 canceled not counted")
    assert has_element?(view, "#initiative-expected", "Dec 12, 2026")
    assert has_element?(view, "#initiative-expected", "19 days left")
    assert has_element?(view, "#initiative-project", "Dishbooks")
    assert has_element?(view, "#initiative-no-briefs", "No update briefs yet.")
    assert has_element?(view, "#create-brief-hint", "listing every ticket done so far")
  end

  test "a sub-issue sits under its parent, and a ticket in a cycle names it", %{
    conn: conn,
    local: local,
    initiative: initiative,
    tickets: [_done, _started, todo]
  } do
    :ok = Issues.close_cycle_day(~D[2026-11-10])
    {:ok, %{cycles: [first | _later]}} = Issues.get_cycles(local)
    {:ok, _todo} = Issues.set_issue_cycle(system_scope(), todo, first.id)
    {:ok, child} = Issues.create_issue(system_scope(), local, %{title: "A part", parent: todo})
    {:ok, child} = Issues.set_issue_initiative(system_scope(), child, initiative.id)

    {:ok, view, _html} = live(conn, ~p"/initiatives/#{initiative.id}")

    assert has_element?(view, "section[aria-label='Todo'] #issue-card-#{todo.id}", "Cycle 1")
    assert has_element?(view, "section[aria-label='Todo'] #issue-card-#{child.id}", "A part")
  end

  test "a sub-issue whose parent is not in the initiative stands alone, and its parent is not listed", %{
    conn: conn,
    local: local,
    initiative: initiative
  } do
    {:ok, parent} = Issues.create_issue(system_scope(), local, %{title: "Umbrella"})
    {:ok, child} = Issues.create_issue(system_scope(), local, %{title: "A part", parent: parent})
    {:ok, _child} = Issues.set_issue_initiative(system_scope(), child, initiative.id)

    {:ok, view, _html} = live(conn, ~p"/initiatives/#{initiative.id}")

    assert has_element?(view, "section[aria-label='Todo'] #issue-card-#{child.id}", "A part")
    refute has_element?(view, "#initiative-tickets [data-context]")
    refute has_element?(view, "#initiative-tickets", "Umbrella")
    assert has_element?(view, "section[aria-label='Todo']", "2 issues")
  end

  test "a sub-issue under a parent in another status group stands alone, and its parent shows once", %{
    conn: conn,
    local: local,
    initiative: initiative,
    tickets: [_done, started, _todo]
  } do
    {:ok, child} = Issues.create_issue(system_scope(), local, %{title: "A part", parent: started})
    {:ok, _child} = Issues.set_issue_initiative(system_scope(), child, initiative.id)

    {:ok, view, _html} = live(conn, ~p"/initiatives/#{initiative.id}")

    assert has_element?(view, "section[aria-label='Todo'] #issue-card-#{child.id}", "A part")
    assert has_element?(view, "section[aria-label='In Progress'] #issue-card-#{started.id}")
    refute has_element?(view, "section[aria-label='Todo'] #issue-card-#{started.id}")
    refute has_element?(view, "#initiative-tickets [data-context]")
  end

  test "someone whose role has no Issues tab is sent to their own home tab", %{
    conn: conn,
    user: user,
    initiative: initiative
  } do
    {:ok, user} = Users.update_user(system_scope(), user, %{role: :support})
    assert {:error, {:redirect, %{to: "/support"}}} = live(log_in_user(conn, user), ~p"/initiatives/#{initiative.id}")
  end

  test "a new initiative reads as empty, with no notes, tickets or date", %{conn: conn, local: local} do
    {:ok, empty} = Initiatives.create_initiative(system_scope(), local, %{name: "Payroll v2"})
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{empty.id}")

    assert has_element?(view, "#initiative-no-notes", "No notes yet.")
    assert has_element?(view, "#initiative-no-tickets", "Add one from an issue's Initiative menu.")
    assert has_element?(view, "#initiative-percent", "0%")
    assert has_element?(view, "#initiative-counts", "0 of 0 tickets")
    refute has_element?(view, "#initiative-counts", "canceled")
    assert has_element?(view, "#initiative-expected", "No expected date")
  end

  test "late and due-today dates read so", %{conn: conn, initiative: initiative} do
    {:ok, _late} = Initiatives.update_initiative(system_scope(), initiative, %{expected_on: ~D[2026-11-20]})
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{initiative.id}")
    assert has_element?(view, "#initiative-expected .text-red-600", "3 days late")

    {:ok, _today} = Initiatives.update_initiative(system_scope(), initiative, %{expected_on: ~D[2026-11-23]})
    assert has_element?(view, "#initiative-expected", "Due today")
  end

  test "the notes are edited as Markdown and saved, and Cancel keeps them", %{conn: conn, initiative: initiative} do
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{initiative.id}")

    view |> element("#edit-notes") |> render_click()
    assert has_element?(view, "#initiative-notes-input[phx-update='ignore']", "### Plan")
    assert has_element?(view, ~s(#notes-form[phx-hook="CommentBox"][data-reopen='{"event":"edit_notes"}']))
    view |> element("#cancel-notes") |> render_click()
    refute has_element?(view, "#notes-form")

    view |> element("#edit-notes") |> render_click()
    view |> form("#notes-form", initiative: %{notes: "## Rules"}) |> render_change()
    {:ok, _renamed} = Initiatives.update_initiative(system_scope(), initiative, %{name: "Renamed elsewhere"})
    assert has_element?(view, "#notes-form")

    view |> form("#notes-form", initiative: %{notes: "## Rules\n\n- No `credo:disable`"}) |> render_submit()

    refute has_element?(view, "#notes-form")
    assert has_element?(view, "#initiative-notes h2", "Rules")
    assert %Initiative{notes: "## Rules\n\n- No `credo:disable`"} = Repo.get!(Initiative, initiative.id)
  end

  test "notes being edited stay open while another tab's write reloads the page", %{
    conn: conn,
    initiative: initiative,
    tickets: [_done, started, _todo]
  } do
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{initiative.id}")
    view |> element("#edit-notes") |> render_click()

    {:ok, _renamed} = Initiatives.update_initiative(system_scope(), initiative, %{name: "Credo cleanup"})
    {:ok, _issue} = Issues.set_issue_status(system_scope(), started, @done)

    assert has_element?(view, "#initiative-name", "Credo cleanup")
    assert has_element?(view, "#initiative-percent", "67%")
    assert has_element?(view, "#notes-form")
  end

  test "Rename and the date edit the name and expected date, and a blank name says why", %{
    conn: conn,
    initiative: initiative
  } do
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{initiative.id}")

    view |> element("#rename-initiative") |> render_click()
    view |> form("#details-form", initiative: %{name: " "}) |> render_submit()
    assert has_element?(view, "#initiative-name-input-error", "can't be blank")

    view |> element("#cancel-details") |> render_click()
    refute has_element?(view, "#details-form")

    view |> element("#initiative-expected") |> render_click()
    view |> form("#details-form", initiative: %{name: "Credo cleanup", expected_on: ""}) |> render_change()
    assert has_element?(view, "#initiative-name-input[value='Credo cleanup']")
    view |> form("#details-form", initiative: %{name: "Credo cleanup", expected_on: ""}) |> render_submit()

    assert has_element?(view, "#initiative-name", "Credo cleanup")
    assert has_element?(view, "#initiative-expected", "No expected date")
    assert %Initiative{name: "Credo cleanup", expected_on: nil} = Repo.get!(Initiative, initiative.id)

    view |> element("#rename-initiative") |> render_click()
    render_keydown(view, "cancel_details", %{"key" => "Escape"})
    refute has_element?(view, "#details-form")
  end

  test "Create update brief posts the snapshot with a Copy button, and a second lists only what finished since", %{
    conn: conn,
    key: key,
    initiative: initiative,
    tickets: [_done, started, _todo]
  } do
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{initiative.id}")

    view |> element("#create-brief") |> render_click()

    assert [%InitiativeComment{id: first_id, body: first}] =
             Repo.all(from(c in InitiativeComment, where: c.initiative_id == ^initiative.id))

    assert first =~ "**Done since the last update (1)**\n- #{key}-1 Two API actions · Paulo"
    assert has_element?(view, "#brief-#{first_id}", "Paulo")
    assert has_element?(view, "#brief-#{first_id} strong", "Credo exclusions")
    assert has_element?(view, "#copy-brief-#{first_id}[phx-hook='CopyText']")
    assert view |> element("#copy-brief-#{first_id}") |> render() =~ ~s(data-copy-text="**Credo exclusions**: update for)
    assert has_element?(view, "#create-brief-hint #since-#{first_id}")
    refute has_element?(view, "#toggle-brief-#{first_id}")

    {:ok, _issue} = Issues.set_issue_status(system_scope(), started, @done)
    view |> element("#create-brief") |> render_click()

    assert %InitiativeComment{id: second_id, body: second} =
             Repo.one(from(c in InitiativeComment, where: c.initiative_id == ^initiative.id and c.id != ^first_id))

    assert second =~ "**Done since the last update (1)**\n- #{key}-2 Banks sync · Paulo"

    html = render(view)
    assert {newer, _older} = :binary.match(html, "brief-#{second_id}")
    assert {older, _length} = :binary.match(html, "brief-#{first_id}")
    assert newer < older

    assert has_element?(view, "#brief-#{first_id} .max-h-40")
    refute has_element?(view, "#brief-#{second_id} .max-h-40")
    view |> element("#toggle-brief-#{first_id}", "Show all") |> render_click()
    refute has_element?(view, "#brief-#{first_id} .max-h-40")
    view |> element("#toggle-brief-#{first_id}", "Show less") |> render_click()
    assert has_element?(view, "#brief-#{first_id} .max-h-40")
  end

  test "a brief Rail posted is signed Rail", %{conn: conn, initiative: initiative} do
    {:ok, %{id: brief_id}} = Initiatives.create_update_brief(system_scope(), initiative)
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{initiative.id}")

    assert has_element?(view, "#brief-#{brief_id}", "Rail")
    assert has_element?(view, "#brief-#{brief_id} [data-qa='issue-unassigned']")
  end

  test "percent done moves without a reload when a ticket moves elsewhere, joins or a cycle closes", %{
    conn: conn,
    local: local,
    initiative: initiative,
    tickets: [_done, started, todo]
  } do
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{initiative.id}")

    fn -> Issues.set_issue_status(system_scope(), started, @done) end |> Task.async() |> Task.await()
    assert has_element?(view, "#initiative-percent", "67%")
    assert has_element?(view, "#initiative-counts", "2 of 3 tickets")

    {:ok, _issue} = Issues.set_issue_status(system_scope(), todo, @canceled)
    assert has_element?(view, "#initiative-counts", "2 of 2 tickets")
    assert has_element?(view, "#initiative-percent", "100%")

    {:ok, joined} = Issues.create_issue(system_scope(), local, %{title: "Joins later"})
    Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_created, joined.id})
    {:ok, _joined} = Issues.set_issue_initiative(system_scope(), joined, initiative.id)
    assert has_element?(view, "#issue-card-#{joined.id}")

    Repo.update_all(from(i in Issue, where: i.id == ^joined.id), set: [state: :done])
    Phoenix.PubSub.broadcast(Rail.PubSub, "cycles", {:cycles_changed, local.id})
    assert has_element?(view, "#initiative-counts", "3 of 3 tickets")

    Repo.update_all(from(i in Issue, where: i.id == ^joined.id), set: [state: :todo])
    Phoenix.PubSub.broadcast(Rail.PubSub, "cycles", {:cycles_changed, "prj_elsewhere"})
    send(view.pid, {:issue_comments_changed, joined.id})
    assert has_element?(view, "#initiative-counts", "3 of 3 tickets")
  end

  test "Delete asks first, then deletes and leaves its tickets with no initiative", %{
    conn: conn,
    initiative: initiative,
    tickets: [done | _rest]
  } do
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{initiative.id}")

    view |> element("#delete-initiative") |> render_click()
    assert has_element?(view, "#delete-initiative-dialog [role='dialog']", "Delete Credo exclusions?")
    assert has_element?(view, "#delete-initiative-dialog", "Its 3 tickets stay where they are, with no initiative.")

    view |> element("#cancel-delete") |> render_click()
    refute has_element?(view, "#delete-initiative-dialog")

    view |> element("#delete-initiative") |> render_click()
    render_keydown(view, "cancel_delete", %{"key" => "Escape"})
    refute has_element?(view, "#delete-initiative-dialog")

    view |> element("#delete-initiative") |> render_click()
    assert {:error, {:live_redirect, %{to: "/initiatives"}}} = view |> element("#confirm-delete") |> render_click()

    refute Repo.get(Initiative, initiative.id)
    assert %Issue{initiative_id: nil} = Repo.get!(Issue, done.id)
  end

  test "the dialog words one ticket and none", %{conn: conn, local: local, tickets: [done | _rest]} do
    {:ok, one} = Initiatives.create_initiative(system_scope(), local, %{name: "One"})
    {:ok, _issue} = Issues.set_issue_initiative(system_scope(), done, one.id)
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{one.id}")
    view |> element("#delete-initiative") |> render_click()
    assert has_element?(view, "#delete-initiative-dialog", "Its 1 ticket stays where it is, with no initiative.")

    {:ok, none} = Initiatives.create_initiative(system_scope(), local, %{name: "None"})
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{none.id}")
    view |> element("#delete-initiative") |> render_click()
    assert has_element?(view, "#delete-initiative-dialog", "It has no tickets.")
  end

  test "an initiative deleted in another tab sends the open page back to Initiatives", %{
    conn: conn,
    initiative: initiative
  } do
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{initiative.id}")

    :ok = Initiatives.delete_initiative(system_scope(), initiative)

    assert_redirect(view, ~p"/initiatives")
  end

  test "Create update brief or Save on an initiative gone meanwhile goes back to Initiatives", %{
    conn: conn,
    local: local,
    initiative: initiative
  } do
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{initiative.id}")
    Repo.delete_all(from(i in Initiative, where: i.id == ^initiative.id))

    view |> element("#create-brief") |> render_click()
    assert {"/initiatives", %{"error" => "Initiative not found"}} = assert_redirect(view)

    {:ok, other} = Initiatives.create_initiative(system_scope(), local, %{name: "Other"})
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{other.id}")
    view |> element("#edit-notes") |> render_click()
    Repo.delete_all(from(i in Initiative, where: i.id == ^other.id))

    assert {:error, {:live_redirect, %{to: "/initiatives"}}} =
             view |> form("#notes-form", initiative: %{notes: "Lost"}) |> render_submit()
  end

  test "an initiative in a project the person cannot open, or none at all, goes back to the list", %{
    conn: conn,
    github_project: other
  } do
    {:ok, hidden} = Initiatives.create_initiative(system_scope(), other, %{name: "Hidden #{System.unique_integer()}"})

    assert {:error, {:live_redirect, %{to: "/initiatives", flash: %{"error" => "Initiative not found"}}}} =
             live(conn, ~p"/initiatives/#{hidden.id}")

    assert {:error, {:live_redirect, %{to: "/initiatives"}}} = live(conn, ~p"/initiatives/ini_missing")
  end
end
