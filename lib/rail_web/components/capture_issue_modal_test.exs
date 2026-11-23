defmodule RailWeb.Components.CaptureIssueModalTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues.Clients.R2
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Users
  alias RailWeb.Components.CaptureIssueModal

  setup {Req.Test, :verify_on_exit!}

  test "renders closed until opened" do
    html = render_component(CaptureIssueModal, id: "capture-issue", projects: [], current_project_id: nil)

    assert html =~ "id=\"capture-issue\""
    refute html =~ "id=\"capture-idea-dialog\""
  end

  test "opens from the top bar with the current project filter selected", %{conn: conn} do
    {:ok, _project1} =
      Projects.create_project(system_scope(), %{
        name: "Project One",
        github_repo: "org/capture-13102",
        github_installation_id: 13_102,
        key: "ONE",
        default_branch: "main",
        clone_path: "/tmp/repos/capture-13102",
        active: true
      })

    {:ok, project2} =
      Projects.create_project(system_scope(), %{
        name: "Project Two",
        github_repo: "org/capture-13103",
        github_installation_id: 13_103,
        key: "TWO",
        default_branch: "main",
        clone_path: "/tmp/repos/capture-13103",
        active: true
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_capture_1",
        login: "capture_user_1",
        email: "capture_user_1@example.com",
        admin: true
      })

    assert {:ok, view, _html} =
             live(init_test_session(log_in_user(conn, user), %{selected_project_id: project2.id}), ~p"/issues")

    refute has_element?(view, "#capture-idea-dialog")

    view |> element("#global-capture-idea-button") |> render_click()

    assert has_element?(view, "#capture-idea-dialog")
    assert has_element?(view, "#new-issue-modal")
    assert has_element?(view, "#capture-modal-title", "New Issue")
    assert has_element?(view, "#capture-project-dropdown option", "Project One (ONE)")
    assert has_element?(view, "#capture-project-dropdown option[value='#{project2.id}'][selected]", "Project Two (TWO)")
    assert has_element?(view, "#capture-priority-dropdown option[value='medium'][selected]")
    assert has_element?(view, "#capture-title-input[value='']")
    assert has_element?(view, "#capture-description-input")
    assert has_element?(view, "#capture-cancel-button")
    assert has_element?(view, "#capture-submit-button[disabled]", "Add to Triage (⌘Enter)")
    refute has_element?(view, "#capture-error-banner")
  end

  test "defaults to the first active project when there is no project filter", %{conn: conn} do
    {:ok, _inactive} =
      Projects.create_project(system_scope(), %{
        name: "Inactive Project",
        github_repo: "org/capture-13105",
        github_installation_id: 13_105,
        key: "INACIM",
        default_branch: "main",
        clone_path: "/tmp/repos/capture-13105",
        active: false
      })

    {:ok, active} =
      Projects.create_project(system_scope(), %{
        name: "Active First",
        github_repo: "org/capture-13106",
        github_installation_id: 13_106,
        key: "ACT",
        default_branch: "main",
        clone_path: "/tmp/repos/capture-13106",
        active: true
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_capture_2",
        login: "capture_user_2",
        email: "capture_user_2@example.com",
        admin: true
      })

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues")

    view |> element("#new-issue-button") |> render_click()

    assert has_element?(view, "#capture-idea-dialog")
    assert has_element?(view, "#capture-project-dropdown option[value='#{active.id}'][selected]")
    refute has_element?(view, "#capture-project-dropdown option", "Inactive Project")
  end

  test "closes from the close and cancel buttons", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_capture_4",
        login: "capture_user_4",
        email: "capture_user_4@example.com",
        admin: true
      })

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues")

    view |> element("#global-capture-idea-button") |> render_click()
    assert has_element?(view, "#capture-idea-dialog")
    assert has_element?(view, "#close-new-issue-button[type='button'][form='capture-issue-form']")

    view |> element("#close-new-issue-button") |> render_click()
    refute has_element?(view, "#capture-idea-dialog")

    view |> element("#global-capture-idea-button") |> render_click()
    assert has_element?(view, "#capture-idea-dialog")

    view |> element("#capture-cancel-button") |> render_click()
    refute has_element?(view, "#capture-idea-dialog")

    expect(Rail.Issues, :create_issue, fn _scope, project, attrs ->
      {:ok, %Issue{id: "iss_close", identifier: "CAP-501", title: attrs.title, state: :triage, project: project}}
    end)

    view |> element("#global-capture-idea-button") |> render_click()

    view
    |> form("#capture-issue-form", %{"title" => "Close the card", "project_id" => project.id, "priority" => "medium"})
    |> render_submit()

    assert has_element?(view, "#capture-created-issue", "CAP-501")

    view |> element("#close-new-issue-button") |> render_click()
    refute has_element?(view, "#capture-idea-dialog")
  end

  test "change keeps the typed values and enables submit", %{conn: conn} do
    {:ok, _project1} =
      Projects.create_project(system_scope(), %{
        name: "Prj 1",
        github_repo: "org/capture-13110",
        github_installation_id: 13_110,
        key: "P13110",
        default_branch: "main",
        clone_path: "/tmp/repos/capture-13110",
        active: true
      })

    {:ok, project2} =
      Projects.create_project(system_scope(), %{
        name: "Prj 2",
        github_repo: "org/capture-13111",
        github_installation_id: 13_111,
        key: "P13111",
        default_branch: "main",
        clone_path: "/tmp/repos/capture-13111",
        active: true
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_capture_5",
        login: "capture_user_5",
        email: "capture_user_5@example.com",
        admin: true
      })

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues")

    view |> element("#global-capture-idea-button") |> render_click()
    assert has_element?(view, "#capture-submit-button[disabled]")

    view
    |> form("#capture-issue-form", %{
      "title" => "Support offline mode",
      "description" => "Cache data locally",
      "project_id" => project2.id,
      "priority" => "urgent"
    })
    |> render_change()

    assert has_element?(view, "#capture-title-input[value='Support offline mode']")
    assert has_element?(view, "#capture-description-input", "Cache data locally")
    assert has_element?(view, "#capture-project-dropdown option[value='#{project2.id}'][selected]")
    assert has_element?(view, "#capture-priority-dropdown option[value='urgent'][selected]")
    refute has_element?(view, "#capture-submit-button[disabled]")

    view |> element("#global-capture-idea-button") |> render_click()

    assert has_element?(view, "#capture-title-input[value='Support offline mode']")
    assert has_element?(view, "#capture-project-dropdown option[value='#{project2.id}'][selected]")
  end

  test "submit does nothing when the title is blank", %{conn: conn} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Capture Project 13113",
        github_repo: "org/capture-13113",
        github_installation_id: 13_113,
        key: "P13113",
        default_branch: "main",
        clone_path: "/tmp/repos/capture-13113",
        active: true
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_capture_6",
        login: "capture_user_6",
        email: "capture_user_6@example.com",
        admin: true
      })

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues")

    view |> element("#global-capture-idea-button") |> render_click()

    view
    |> form("#capture-issue-form", %{
      "title" => "   ",
      "description" => "Has a description but no title",
      "project_id" => project.id,
      "priority" => "medium"
    })
    |> render_submit()

    assert has_element?(view, "#capture-idea-dialog")
    refute has_element?(view, "#capture-error-banner")
    assert Repo.all(Issue) == []
  end

  test "submit shows Project not found when the project is not one it was given", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_capture_7",
        login: "capture_user_7",
        email: "capture_user_7@example.com",
        admin: true
      })

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues")

    view |> element("#global-capture-idea-button") |> render_click()

    render_submit(element(view, "#capture-issue-form"), %{
      "title" => "Some idea",
      "project_id" => "nonexistent_project_id",
      "priority" => "medium"
    })

    assert has_element?(view, "#capture-idea-dialog")
    assert has_element?(view, "#capture-error-banner", "Project not found")
    assert has_element?(view, "#capture-title-input[value='Some idea']")
  end

  test "submit creates the issue and shows it in the dialog, linked to its page and openable in a new tab", %{
    conn: conn,
    project: %{id: project_id} = project
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_capture_8",
        login: "capture_user_8",
        email: "capture_user_8@example.com",
        admin: true
      })

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/")

    view |> element("#global-capture-idea-button") |> render_click()

    view
    |> form("#capture-issue-form", %{
      "title" => "Capture via LiveView",
      "description" => "Multiline\nbody",
      "project_id" => project.id,
      "priority" => "high"
    })
    |> render_submit()

    assert %Issue{
             id: issue_id,
             project_id: ^project_id,
             identifier: identifier,
             url: url,
             description: "Multiline\nbody",
             priority: :high
           } = Repo.get_by!(Issue, title: "Capture via LiveView")

    assert has_element?(view, "#capture-idea-dialog #capture-created[role='status']", "Created in Triage")
    assert has_element?(view, "#capture-created-issue[href='/issues/#{issue_id}']", identifier)
    assert has_element?(view, "#capture-created-issue", "Capture via LiveView")
    assert has_element?(view, "#capture-created", "#{project.name} (#{project.key})")
    assert has_element?(view, "#capture-created", "High")

    assert has_element?(
             view,
             "#capture-created-tracker[href='#{url}'][target='_blank']",
             "Open issue"
           )

    refute has_element?(view, "#capture-issue-form")
    refute has_element?(view, "#capture-error-banner")

    view |> element("#global-capture-idea-button") |> render_click()
    assert has_element?(view, "#capture-created-issue", identifier)

    view |> element("#capture-created-issue") |> render_click()
    assert_redirect(view, ~p"/issues/#{issue_id}")
  end

  test "a screenshot pasted into Description goes up under the id the new issue is then created with", %{
    conn: conn,
    project: %{id: project_id} = project
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_capture_paste",
        login: "capture_user_paste",
        email: "capture_user_paste@example.com",
        admin: true
      })

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/")

    view |> element("#global-capture-idea-button") |> render_click()

    assert has_element?(view, "#capture-idea-dialog[data-file-drop]")

    assert has_element?(
             view,
             "#capture-description-input[phx-hook='MarkdownPaste'][data-upload-form='capture-issue-upload']"
           )

    assert has_element?(view, "#capture-priority-dropdown[form='capture-issue-form']")
    assert has_element?(view, "#capture-submit-button[form='capture-issue-form']", "Uploading...")

    Req.Test.expect(R2, 2, fn r2 -> Plug.Conn.send_resp(r2, 200, "") end)

    view
    |> file_input("#capture-issue-upload", :file, [%{name: "round 1.png", content: "PNG_BYTES", type: "image/png"}])
    |> render_upload("round 1.png")

    render_async(view)
    assert_push_event(view, "insert_file", %{form: "capture-issue-upload", url: url, image: true})
    assert [_url, "iss_" <> _drawn = drawn_id] = Regex.run(~r"/issues/(iss_\w+)/assets/", url)

    view
    |> form("#capture-issue-form", %{
      "title" => "Fix round count reads 0",
      "description" => "Header after round 1:\n\n![round 1.png](#{url})",
      "project_id" => project.id,
      "priority" => "medium"
    })
    |> render_submit()

    assert %Issue{id: ^drawn_id, project_id: ^project_id, description: "Header after round 1:" <> _image} =
             Repo.get_by!(Issue, title: "Fix round count reads 0")

    stub(Rail.Issues, :link_pull_request, fn _scope, _issue -> {:ok, nil} end)
    {:ok, page, _html} = live(log_in_user(conn, user), ~p"/issues/#{drawn_id}")
    assert has_element?(page, "#issue-description-#{drawn_id} img[src='#{url}']")

    view |> element("#capture-created-new") |> render_click()

    view
    |> file_input("#capture-issue-upload", :file, [%{name: "next.png", content: "PNG_BYTES", type: "image/png"}])
    |> render_upload("next.png")

    render_async(view)
    assert_push_event(view, "insert_file", %{form: "capture-issue-upload", url: next_url})
    refute next_url =~ drawn_id
    assert next_url =~ ~r"/issues/iss_\w+/assets/"
  end

  test "a second submit while the created issue shows creates nothing more", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_capture_10",
        login: "capture_user_10",
        email: "capture_user_10@example.com",
        admin: true
      })

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues")

    view |> element("#global-capture-idea-button") |> render_click()

    expect(Rail.Issues, :create_issue, fn _scope, %{id: project_id} = project, %{title: "Only once"} = attrs ->
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project_id,
        identifier: "CAP-301",
        title: attrs.title,
        state: :triage,
        url: "https://rail.test/issues/cap-301"
      })
      |> Repo.insert()
      |> then(fn {:ok, issue} -> {:ok, %{issue | project: project}} end)
    end)

    params = %{"title" => "Only once", "project_id" => project.id, "priority" => "medium"}
    view |> form("#capture-issue-form", params) |> render_submit()

    assert has_element?(view, "#capture-created-issue", "CAP-301")

    view |> with_target("#capture-issue") |> render_submit("submit", params)

    assert [%Issue{identifier: "CAP-301"}] = Repo.all(Issue)
    assert has_element?(view, "#capture-created-issue", "CAP-301")
  end

  test "the confirmation names the state the issue was filed in", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_capture_14",
        login: "capture_user_14",
        email: "capture_user_14@example.com",
        admin: true
      })

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues")

    view |> element("#global-capture-idea-button") |> render_click()

    expect(Rail.Issues, :create_issue, fn _scope, %{id: project_id} = project, attrs ->
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project_id,
        identifier: "CAP-302",
        title: attrs.title,
        state: :backlog
      })
      |> Repo.insert()
      |> then(fn {:ok, issue} -> {:ok, %{issue | project: project}} end)
    end)

    view
    |> form("#capture-issue-form", %{"title" => "No triage here", "project_id" => project.id, "priority" => "medium"})
    |> render_submit()

    assert has_element?(view, "#capture-created", "Created in Backlog")
    refute has_element?(view, "#capture-created", "Created in Triage")
  end

  test "an issue a teammate creates never appears in the confirmation", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_capture_11",
        login: "capture_user_11",
        email: "capture_user_11@example.com",
        admin: true
      })

    assert {:ok, view, _html} =
             live(init_test_session(log_in_user(conn, user), %{selected_project_id: project.id}), ~p"/issues")

    view |> element("#global-capture-idea-button") |> render_click()

    expect(Rail.Issues, :create_issue, fn _scope, project, attrs ->
      {:ok, %Issue{id: "iss_mine", identifier: "CAP-401", title: attrs.title, state: :triage, project: project}}
    end)

    view
    |> form("#capture-issue-form", %{"title" => "Mine", "project_id" => project.id, "priority" => "medium"})
    |> render_submit()

    {:ok, %Issue{id: teammate_issue_id}} =
      Repo.insert(
        Issue.tracker_changeset(%Issue{}, %{
          project_id: project.id,
          identifier: "CAP-402",
          title: "A teammate's issue",
          state: :triage
        })
      )

    Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_created, teammate_issue_id})

    assert has_element?(view, "#issues-list [data-qa='issue-title']", "A teammate's issue")
    assert has_element?(view, "#capture-created-issue[href='/issues/iss_mine']", "CAP-401")
    refute has_element?(view, "#capture-created", "CAP-402")
    refute has_element?(view, "#capture-created-tracker")
  end

  test "a created issue in another project opens in a new tab and keeps its long title whole", %{
    conn: conn,
    github_project: other_project
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_capture_12",
        login: "capture_user_12",
        email: "capture_user_12@example.com",
        admin: true
      })

    title =
      "Recipe import keeps ingredient order, quantities and the source page's section headings when the page splits a recipe across tabs"

    issue =
      github_issue(other_project, %{
        number: 214,
        title: title,
        priority: :urgent,
        state: :triage,
        url: "https://rail.test/issues/tgh-214"
      })

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/")

    view |> element("#global-capture-idea-button") |> render_click()

    expect(Rail.Issues, :create_issue, fn _scope, _project, %{title: ^title, priority: :urgent} -> {:ok, issue} end)

    view
    |> form("#capture-issue-form", %{"title" => title, "project_id" => other_project.id, "priority" => "urgent"})
    |> render_submit()

    assert has_element?(view, "#capture-created-issue[href='/issues/#{issue.id}']", "tgh-214")
    assert has_element?(view, "#capture-created-issue", title)
    assert has_element?(view, "#capture-created", "Urgent")

    assert has_element?(
             view,
             "#capture-created-tracker[href='https://rail.test/issues/tgh-214'][target='_blank']",
             "Open issue"
           )
  end

  test "New issue and opening the dialog again both start from an empty form with today's defaults", %{
    conn: conn,
    project: project
  } do
    {:ok, other} =
      Projects.create_project(system_scope(), %{
        name: "Other Project",
        github_repo: "org/capture-13120",
        github_installation_id: 13_120,
        key: "OTHCIM",
        default_branch: "main",
        clone_path: "/tmp/repos/capture-13120",
        active: true
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_capture_13",
        login: "capture_user_13",
        email: "capture_user_13@example.com",
        admin: true
      })

    assert {:ok, view, _html} =
             live(init_test_session(log_in_user(conn, user), %{selected_project_id: project.id}), ~p"/issues")

    stub(Rail.Issues, :create_issue, fn _scope, project, attrs ->
      {:ok, %Issue{id: "iss_reset", identifier: "OTHCIM-1", title: attrs.title, state: :triage, project: project}}
    end)

    filled = %{"title" => "Filed", "description" => "Body", "project_id" => other.id, "priority" => "low"}

    view |> element("#global-capture-idea-button") |> render_click()
    view |> form("#capture-issue-form", filled) |> render_submit()

    view |> element("#capture-created-new") |> render_click()

    refute has_element?(view, "#capture-created")
    assert has_element?(view, "#capture-title-input[value=''][phx-mounted]")
    refute has_element?(view, "#capture-title-input[autofocus]")
    refute has_element?(view, "#capture-description-input", "Body")
    assert has_element?(view, "#capture-project-dropdown option[value='#{project.id}'][selected]")
    assert has_element?(view, "#capture-priority-dropdown option[value='medium'][selected]")

    view |> form("#capture-issue-form", filled) |> render_submit()
    view |> element("#capture-created-close") |> render_click()

    refute has_element?(view, "#capture-idea-dialog")

    view |> element("#global-capture-idea-button") |> render_click()

    refute has_element?(view, "#capture-created")
    assert has_element?(view, "#capture-title-input[value=''][phx-mounted]")
    refute has_element?(view, "#capture-title-input[autofocus]")
    assert has_element?(view, "#capture-project-dropdown option[value='#{project.id}'][selected]")
    assert has_element?(view, "#capture-priority-dropdown option[value='medium'][selected]")
  end

  test "submit keeps the dialog open with the values and shows the error when creating fails", %{conn: conn} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Capture Project 13117",
        github_repo: "org/capture-13117",
        github_installation_id: 13_117,
        key: "P13117",
        default_branch: "main",
        clone_path: "/tmp/repos/capture-13117",
        active: true
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_capture_9",
        login: "capture_user_9",
        email: "capture_user_9@example.com",
        admin: true
      })

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues")

    view |> element("#global-capture-idea-button") |> render_click()

    expect(Rail.Issues, :create_issue, fn _scope, _project, %{title: "Critical production defect", priority: :urgent} ->
      {:error, %Ecto.Changeset{}}
    end)

    view
    |> form("#capture-issue-form", %{
      "title" => "Critical production defect",
      "description" => "Checkout returns 500",
      "project_id" => project.id,
      "priority" => "urgent"
    })
    |> render_submit()

    assert has_element?(view, "#capture-idea-dialog")
    assert has_element?(view, "#capture-title-input[value='Critical production defect']")
    assert has_element?(view, "#capture-description-input", "Checkout returns 500")
    assert has_element?(view, "#capture-priority-dropdown option[value='urgent'][selected]")
    assert has_element?(view, "#capture-error-banner", "Could not create the issue")
    refute has_element?(view, "#capture-created")
  end
end
