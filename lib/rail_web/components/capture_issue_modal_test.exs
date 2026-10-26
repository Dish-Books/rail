defmodule RailWeb.Components.CaptureIssueModalTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Users
  alias RailWeb.Components.CaptureIssueModal

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
        linear_state_ids: %{"triage" => "st_triage"},
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
        linear_state_ids: %{"triage" => "st_triage"},
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
        key: "INA",
        default_branch: "main",
        clone_path: "/tmp/repos/capture-13105",
        linear_state_ids: %{"triage" => "st_triage"},
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
        linear_state_ids: %{"triage" => "st_triage"},
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
        linear_state_ids: %{"triage" => "st_triage"},
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
        linear_state_ids: %{"triage" => "st_triage"},
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
        linear_state_ids: %{"triage" => "st_triage"},
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

  test "submit creates the issue as the user and shows it in the dialog with links to Rail and Linear", %{
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

    {:ok, user} =
      Users.update_user(system_scope(), user, %{
        linear_access_token: "lin_capture_user_token",
        linear_refresh_token: "lin_capture_user_refresh",
        linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer lin_capture_user_token"]

      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_capture_ok",
              "identifier" => "CAP-101",
              "title" => "Capture via LiveView",
              "description" => "Multiline\nbody",
              "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
              "branchName" => "cap-101-branch",
              "url" => "https://linear.app/issue/CAP-101"
            }
          }
        }
      })
    end)

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

    assert %Issue{id: issue_id, project_id: ^project_id, identifier: "CAP-101", priority: :high} =
             Repo.get_by(Issue, external_id: "lin_capture_ok")

    assert has_element?(view, "#capture-idea-dialog #capture-created[role='status']", "Created in Triage")
    assert has_element?(view, "#capture-created-issue[href='/issues/#{issue_id}']", "CAP-101")
    assert has_element?(view, "#capture-created-issue", "Capture via LiveView")
    assert has_element?(view, "#capture-created", "#{project.name} (#{project.key})")
    assert has_element?(view, "#capture-created", "High")

    assert has_element?(
             view,
             "#capture-created-tracker[href='https://linear.app/issue/CAP-101'][target='_blank']",
             "Open in Linear"
           )

    refute has_element?(view, "#capture-issue-form")
    refute has_element?(view, "#capture-error-banner")

    view |> element("#global-capture-idea-button") |> render_click()
    assert has_element?(view, "#capture-created-issue", "CAP-101")

    view |> element("#capture-created-issue") |> render_click()
    assert_redirect(view, ~p"/issues/#{issue_id}")
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
        external_id: "lin_capture_once",
        identifier: "CAP-301",
        title: attrs.title,
        state: :triage,
        url: "https://linear.app/issue/CAP-301"
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

  test "the confirmation names the state the tracker filed the issue in", %{conn: conn, project: project} do
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
        external_id: "lin_capture_backlog",
        identifier: "CAP-302",
        title: attrs.title,
        state: :triage,
        state_name: "Backlog"
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
          external_id: "lin_capture_teammate",
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

  test "a GitHub project's created issue opens in GitHub and keeps its long title whole", %{
    conn: conn,
    github_project: github_project
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
      github_issue(github_project, %{
        number: 214,
        identifier: "tgh#214",
        title: title,
        priority: :urgent,
        state: :triage,
        url: "https://github.com/example/test-gh/issues/214"
      })

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/")

    view |> element("#global-capture-idea-button") |> render_click()

    expect(Rail.Issues, :create_issue, fn _scope, _project, %{title: ^title, priority: :urgent} -> {:ok, issue} end)

    view
    |> form("#capture-issue-form", %{"title" => title, "project_id" => github_project.id, "priority" => "urgent"})
    |> render_submit()

    assert has_element?(view, "#capture-created-issue[href='/issues/#{issue.id}']", "tgh#214")
    assert has_element?(view, "#capture-created-issue", title)
    assert has_element?(view, "#capture-created", "Urgent")

    assert has_element?(
             view,
             "#capture-created-tracker[href='https://github.com/example/test-gh/issues/214'][target='_blank']",
             "Open in GitHub"
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
        key: "OTH",
        default_branch: "main",
        clone_path: "/tmp/repos/capture-13120",
        linear_state_ids: %{"triage" => "st_triage"},
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
      {:ok, %Issue{id: "iss_reset", identifier: "OTH-1", title: attrs.title, state: :triage, project: project}}
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
        linear_state_ids: %{"triage" => "st_triage_err"},
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

    expect(Rail.Issues, :create_issue, fn _scope, _project, _attrs -> {:error, "Direct string failure"} end)

    render_submit(element(view, "#capture-issue-form"), %{
      "title" => "Testing string error",
      "project_id" => project.id,
      "priority" => "medium"
    })

    assert has_element?(view, "#capture-error-banner", "Direct string failure")

    expect(Rail.Issues, :create_issue, fn _scope, _project, _attrs -> {:error, :not_authorized} end)

    render_submit(element(view, "#capture-issue-form"), %{
      "title" => "Testing atom error",
      "project_id" => project.id,
      "priority" => "medium"
    })

    assert has_element?(view, "#capture-error-banner", ":not_authorized")

    for {reason, message} <-
          [
            github_issues_permission_missing: "The GitHub App needs Issues: read and write on this repository",
            github_issues_disabled: "Issues are turned off on this repository",
            linear_team_not_found: "This project has no Linear team",
            no_workspace_token: "Rail is not connected to this project's Linear workspace"
          ] ++
            [
              {{:linear_graphql_error, [%{"message" => "Title is too long"}, %{"message" => "Second"}]},
               "Linear refused the issue: Title is too long"},
              {{:linear_api_error, 400, %{"errors" => [%{"message" => "Team is archived"}]}},
               "Linear refused the issue: Team is archived"},
              {{:linear_api_error, 503, "Service Unavailable"}, "Linear could not create the issue (503)"},
              {{:linear_mutation_failed, "issueCreate"}, "Linear did not create the issue"},
              {{:github_api_error, 422, %{"message" => "Validation Failed"}}, "GitHub could not create the issue (422)"},
              {%Req.TransportError{reason: :timeout}, "Could not reach the tracker (timeout)"}
            ] do
      expect(Rail.Issues, :create_issue, fn _scope, _project, _attrs -> {:error, reason} end)

      render_submit(element(view, "#capture-issue-form"), %{
        "title" => "Testing GitHub error",
        "project_id" => project.id,
        "priority" => "medium"
      })

      assert has_element?(view, "#capture-error-banner", message)
    end
  end
end
