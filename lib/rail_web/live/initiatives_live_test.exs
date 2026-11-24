defmodule RailWeb.InitiativesLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Initiatives
  alias Rail.Initiatives.Schemas.Initiative
  alias Rail.Issues
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Users

  @done %{id: "done", name: "Done", state: :done}
  @in_progress %{id: "in_progress", name: "In Progress", state: :in_progress}
  @canceled %{id: "canceled", name: "Canceled", state: :canceled}

  setup %{conn: conn} do
    [%{key: key} = dis, rail] =
      for name <- ["Dishbooks", "Rail"] do
        key = "IL#{System.unique_integer([:positive])}"

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
      Users.register_oauth_user(%{github_id: "gh_#{key}", login: "il_#{key}", name: "Ini", email: "#{key}@example.com"})

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [dis.id, rail.id]})
    stub(Date, :utc_today, fn -> ~D[2026-11-23] end)

    %{conn: log_in_user(conn, user), dis: dis, rail: rail, user: user}
  end

  test "the nav opens Initiatives, which lists each with its project, progress, tickets and expected date", %{
    conn: conn,
    dis: dis,
    rail: rail
  } do
    {:ok, %{id: late_id}} =
      Initiatives.create_initiative(system_scope(), dis, %{name: "Bank feeds", expected_on: ~D[2026-11-20]})

    {:ok, %{id: today_id}} =
      Initiatives.create_initiative(system_scope(), dis, %{name: "Square POS", expected_on: ~D[2026-11-23]})

    {:ok, %{id: credo_id} = credo} =
      Initiatives.create_initiative(system_scope(), dis, %{name: "Credo exclusions", expected_on: ~D[2026-12-12]})

    {:ok, %{id: none_id}} = Initiatives.create_initiative(system_scope(), rail, %{name: "Payroll v2"})

    for status <- [@done, @in_progress, nil] do
      {:ok, issue} = Issues.create_issue(system_scope(), dis, %{title: "Credo work"})
      {:ok, issue} = Issues.set_issue_initiative(system_scope(), issue, credo.id)
      if status, do: {:ok, _issue} = Issues.set_issue_status(system_scope(), issue, status)
    end

    {:ok, overview, _html} = live(conn, ~p"/")
    assert has_element?(overview, "#nav-initiatives[href='/initiatives']")
    assert {:ok, view, _html} = overview |> element("#nav-initiatives") |> render_click() |> follow_redirect(conn)

    assert has_element?(view, "#section-title", "Initiatives")
    assert has_element?(view, "#nav-initiatives[data-active='true']")
    assert has_element?(view, "#initiatives-subtitle", "Initiatives across all projects")
    assert has_element?(view, "#sort-expected[aria-sort='ascending']")

    rows = view |> render() |> Floki.parse_document!() |> Floki.find("#initiatives-list a[id^='initiative-']")

    assert Enum.map(rows, &(&1 |> Floki.attribute("id") |> hd())) ==
             Enum.map([late_id, today_id, credo_id, none_id], &"initiative-#{&1}")

    assert has_element?(view, "#initiative-#{credo_id}[href='/initiatives/#{credo_id}']", dis.key)
    assert has_element?(view, "#initiative-#{credo_id} [role='progressbar'][aria-valuenow='33']")
    assert has_element?(view, "#initiative-#{credo_id}", "33%")
    assert has_element?(view, "#initiative-#{credo_id}", "1 of 3 tickets")
    assert has_element?(view, "#initiative-#{credo_id}", "Dec 12 · 19 days left")
    assert has_element?(view, "#initiative-#{today_id}", "Due today")
    assert has_element?(view, "#initiative-#{late_id} .text-red-600", "Nov 20 · 3 days late")
    assert has_element?(view, "#initiative-#{none_id}", "No expected date")
    assert has_element?(view, "#initiative-#{none_id}", "0 of 0 tickets")
  end

  test "the headers sort by name and by progress, kept in the URL", %{conn: conn, dis: dis} do
    {:ok, %{id: zebra_id} = zebra} = Initiatives.create_initiative(system_scope(), dis, %{name: "Zebra"})
    {:ok, %{id: apple_id}} = Initiatives.create_initiative(system_scope(), dis, %{name: "Apple"})
    {:ok, issue} = Issues.create_issue(system_scope(), dis, %{title: "Done work"})
    {:ok, issue} = Issues.set_issue_initiative(system_scope(), issue, zebra.id)
    {:ok, _issue} = Issues.set_issue_status(system_scope(), issue, @done)

    {:ok, view, _html} = live(conn, ~p"/initiatives")

    ids = fn ->
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.find("#initiatives-list a[id^='initiative-']")
      |> Enum.flat_map(&Floki.attribute(&1, "id"))
    end

    view |> element("#sort-name") |> render_click()
    assert_patch(view, ~p"/initiatives?sort=name")
    assert has_element?(view, "#sort-name[aria-sort='ascending']")
    assert ids.() == ["initiative-#{apple_id}", "initiative-#{zebra_id}"]

    view |> element("#sort-progress") |> render_click()
    assert_patch(view, ~p"/initiatives?sort=progress")
    assert has_element?(view, "#sort-progress[aria-sort='descending']")
    refute has_element?(view, "#sort-name[aria-sort]")
    assert ids.() == ["initiative-#{zebra_id}", "initiative-#{apple_id}"]
  end

  test "percent done moves without a reload as a ticket finishes, and a canceled one drops out", %{
    conn: conn,
    dis: dis
  } do
    {:ok, %{id: credo_id} = credo} = Initiatives.create_initiative(system_scope(), dis, %{name: "Credo exclusions"})

    [first, second, third] =
      for title <- ["DIS-2363", "DIS-2364", "DIS-2365"] do
        {:ok, issue} = Issues.create_issue(system_scope(), dis, %{title: title})
        {:ok, issue} = Issues.set_issue_initiative(system_scope(), issue, credo.id)
        issue
      end

    {:ok, _issue} = Issues.set_issue_status(system_scope(), first, @done)
    {:ok, _issue} = Issues.set_issue_status(system_scope(), second, @in_progress)

    {:ok, view, _html} = live(conn, ~p"/initiatives")
    assert has_element?(view, "#initiative-#{credo_id}", "1 of 3 tickets")

    # 2 of 3 reads 67%, the ticket's number.
    fn -> Issues.set_issue_status(system_scope(), second, @done) end |> Task.async() |> Task.await()
    assert has_element?(view, "#initiative-#{credo_id} [role='progressbar'][aria-valuenow='67']")
    assert has_element?(view, "#initiative-#{credo_id}", "2 of 3 tickets")

    {:ok, _issue} = Issues.set_issue_status(system_scope(), third, @canceled)
    assert has_element?(view, "#initiative-#{credo_id}", "2 of 2 tickets")
    assert has_element?(view, "#initiative-#{credo_id}", "100%")

    {:ok, _renamed} = Initiatives.update_initiative(system_scope(), credo, %{name: "Credo cleanup"})
    assert has_element?(view, "#initiative-#{credo_id}", "Credo cleanup")
  end

  test "with All projects the form asks for one, and creating opens the new initiative", %{
    conn: conn,
    dis: %{id: dis_id} = dis
  } do
    {:ok, view, _html} = live(conn, ~p"/initiatives")
    refute has_element?(view, "#new-initiative-form")

    view |> element("#new-initiative-button") |> render_click()
    assert has_element?(view, "#new-initiative-project option[value='#{dis_id}']", "Dishbooks (#{dis.key})")

    view |> element("#cancel-new-initiative") |> render_click()
    refute has_element?(view, "#new-initiative-form")
    view |> element("#new-initiative-button") |> render_click()

    view |> form("#new-initiative-form", initiative: %{name: "Credo", project_id: dis_id}) |> render_change()
    assert has_element?(view, "#new-initiative-project option[value='#{dis_id}'][selected]")
    refute has_element?(view, "#new-initiative-name-error")

    assert {:error, {:live_redirect, %{to: "/initiatives/" <> id}}} =
             view
             |> form("#new-initiative-form",
               initiative: %{name: "Credo exclusions", project_id: dis_id, expected_on: "2026-12-12"}
             )
             |> render_submit()

    assert %Initiative{project_id: ^dis_id, name: "Credo exclusions", expected_on: ~D[2026-12-12]} =
             Repo.get!(Initiative, id)
  end

  test "with a project selected the form takes it, a taken name says so, and Escape closes it", %{
    conn: conn,
    dis: %{id: dis_id} = dis
  } do
    {:ok, _taken} = Initiatives.create_initiative(system_scope(), dis, %{name: "Credo exclusions"})
    {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: dis_id}), ~p"/initiatives")

    assert has_element?(view, "#initiatives-subtitle", "Dishbooks")
    view |> element("#new-initiative-button") |> render_click()
    refute has_element?(view, "#new-initiative-project")

    view |> form("#new-initiative-form", initiative: %{name: "credo EXCLUSIONS"}) |> render_submit()
    assert has_element?(view, "#new-initiative-name-error", "is already an initiative here")

    assert {:error, {:live_redirect, %{to: "/initiatives/" <> id}}} =
             view |> form("#new-initiative-form", initiative: %{name: "Payroll v2"}) |> render_submit()

    assert %Initiative{project_id: ^dis_id, expected_on: nil} = Repo.get!(Initiative, id)

    {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: dis_id}), ~p"/initiatives")
    view |> element("#new-initiative-button") |> render_click()
    render_keydown(view, "cancel_new", %{"key" => "Escape"})
    refute has_element?(view, "#new-initiative-form")
  end

  test "a project not offered is refused, and nothing is created", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/initiatives")
    view |> element("#new-initiative-button") |> render_click()

    render_submit(view, "create", %{"initiative" => %{"name" => "Sneaky", "project_id" => "prj_elsewhere"}})

    assert has_element?(view, "#new-initiative-form")
    refute Repo.get_by(Initiative, name: "Sneaky")
  end

  test "an empty list names the selected project, or the person's projects", %{conn: conn, dis: dis} do
    {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: dis.id}), ~p"/initiatives")
    assert has_element?(view, "#initiatives-empty", "No initiatives in Dishbooks yet")

    {:ok, view, _html} = live(conn, ~p"/initiatives")
    assert has_element?(view, "#initiatives-empty", "No initiatives in your projects yet")
  end

  test "someone whose role has no Issues tab is sent to their own home tab", %{conn: conn, user: user} do
    {:ok, user} = Users.update_user(system_scope(), user, %{role: :support})
    assert {:error, {:redirect, %{to: "/support"}}} = live(log_in_user(conn, user), ~p"/initiatives")
  end

  test "someone without access to a project sees none of its initiatives with All projects", %{
    conn: conn,
    user: user,
    dis: dis,
    rail: rail
  } do
    {:ok, %{id: hidden_id}} = Initiatives.create_initiative(system_scope(), dis, %{name: "Hidden"})
    {:ok, %{id: shown_id}} = Initiatives.create_initiative(system_scope(), rail, %{name: "Shown"})
    {:ok, _user} = Users.update_user(system_scope(), user, %{project_ids: [rail.id]})

    {:ok, view, _html} = live(conn, ~p"/initiatives")

    assert has_element?(view, "#initiative-#{shown_id}")
    refute has_element?(view, "#initiative-#{hidden_id}")
    refute render(view) =~ "Hidden"

    send(view.pid, {:issue_comments_changed, "iss_elsewhere"})
    assert has_element?(view, "#initiative-#{shown_id}")
  end
end
