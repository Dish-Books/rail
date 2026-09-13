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
        linear_team_id: "team_capture_13102",
        linear_team_key: "ONE",
        default_branch: "main",
        clone_path: "/tmp/repos/capture-13102",
        linear_state_ids: %{"triage" => "st_triage"},
        linear_workspace: %{
          name: "Capture Workspace 13102",
          external_id: "lin_ws_capture_13102",
          token: "lin_api_token_capture_13102",
          webhook_secret: "whsec_capture_13102"
        },
        active: true
      })

    {:ok, project2} =
      Projects.create_project(system_scope(), %{
        name: "Project Two",
        github_repo: "org/capture-13103",
        github_installation_id: 13_103,
        linear_team_id: "team_capture_13103",
        linear_team_key: "TWO",
        default_branch: "main",
        clone_path: "/tmp/repos/capture-13103",
        linear_state_ids: %{"triage" => "st_triage"},
        linear_workspace: %{
          name: "Capture Workspace 13103",
          external_id: "lin_ws_capture_13103",
          token: "lin_api_token_capture_13103",
          webhook_secret: "whsec_capture_13103"
        },
        active: true
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_capture_1",
        login: "capture_user_1",
        email: "capture_user_1@example.com",
        admin: true
      })

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues?project=#{project2.id}")

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
    assert has_element?(view, "#capture-submit-button[disabled]", "Add to Backlog (⌘Enter)")
    refute has_element?(view, "#capture-error-banner")
  end

  test "defaults to the first active project when there is no project filter", %{conn: conn} do
    {:ok, _inactive} =
      Projects.create_project(system_scope(), %{
        name: "Inactive Project",
        github_repo: "org/capture-13105",
        github_installation_id: 13_105,
        linear_team_id: "team_capture_13105",
        linear_team_key: "INA",
        default_branch: "main",
        clone_path: "/tmp/repos/capture-13105",
        linear_state_ids: %{"triage" => "st_triage"},
        linear_workspace: %{
          name: "Capture Workspace 13105",
          external_id: "lin_ws_capture_13105",
          token: "lin_api_token_capture_13105",
          webhook_secret: "whsec_capture_13105"
        },
        active: false
      })

    {:ok, active} =
      Projects.create_project(system_scope(), %{
        name: "Active First",
        github_repo: "org/capture-13106",
        github_installation_id: 13_106,
        linear_team_id: "team_capture_13106",
        linear_team_key: "ACT",
        default_branch: "main",
        clone_path: "/tmp/repos/capture-13106",
        linear_state_ids: %{"triage" => "st_triage"},
        linear_workspace: %{
          name: "Capture Workspace 13106",
          external_id: "lin_ws_capture_13106",
          token: "lin_api_token_capture_13106",
          webhook_secret: "whsec_capture_13106"
        },
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

  test "opens with no project selected when there are no active projects", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_capture_3",
        login: "capture_user_3",
        email: "capture_user_3@example.com",
        admin: true
      })

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues")

    view |> element("#global-capture-idea-button") |> render_click()

    assert has_element?(view, "#capture-idea-dialog")
    refute has_element?(view, "#capture-project-dropdown option")
  end

  test "closes from the close and cancel buttons", %{conn: conn} do
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

    view |> element("#close-new-issue-button") |> render_click()
    refute has_element?(view, "#capture-idea-dialog")

    view |> element("#global-capture-idea-button") |> render_click()
    assert has_element?(view, "#capture-idea-dialog")

    view |> element("#capture-cancel-button") |> render_click()
    refute has_element?(view, "#capture-idea-dialog")
  end

  test "change keeps the typed values and enables submit", %{conn: conn} do
    {:ok, _project1} =
      Projects.create_project(system_scope(), %{
        name: "Prj 1",
        github_repo: "org/capture-13110",
        github_installation_id: 13_110,
        linear_team_id: "team_capture_13110",
        linear_team_key: "P13110",
        default_branch: "main",
        clone_path: "/tmp/repos/capture-13110",
        linear_state_ids: %{"triage" => "st_triage"},
        linear_workspace: %{
          name: "Capture Workspace 13110",
          external_id: "lin_ws_capture_13110",
          token: "lin_api_token_capture_13110",
          webhook_secret: "whsec_capture_13110"
        },
        active: true
      })

    {:ok, project2} =
      Projects.create_project(system_scope(), %{
        name: "Prj 2",
        github_repo: "org/capture-13111",
        github_installation_id: 13_111,
        linear_team_id: "team_capture_13111",
        linear_team_key: "P13111",
        default_branch: "main",
        clone_path: "/tmp/repos/capture-13111",
        linear_state_ids: %{"triage" => "st_triage"},
        linear_workspace: %{
          name: "Capture Workspace 13111",
          external_id: "lin_ws_capture_13111",
          token: "lin_api_token_capture_13111",
          webhook_secret: "whsec_capture_13111"
        },
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
  end

  test "submit does nothing when the title is blank", %{conn: conn} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Capture Project 13113",
        github_repo: "org/capture-13113",
        github_installation_id: 13_113,
        linear_team_id: "team_capture_13113",
        linear_team_key: "P13113",
        default_branch: "main",
        clone_path: "/tmp/repos/capture-13113",
        linear_state_ids: %{"triage" => "st_triage"},
        linear_workspace: %{
          name: "Capture Workspace 13113",
          external_id: "lin_ws_capture_13113",
          token: "lin_api_token_capture_13113",
          webhook_secret: "whsec_capture_13113"
        },
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

  test "submit creates the issue and closes", %{conn: conn} do
    {:ok, %{id: project_id} = project} =
      Projects.create_project(system_scope(), %{
        name: "Capture Project 13115",
        github_repo: "org/capture-13115",
        github_installation_id: 13_115,
        linear_team_id: "team_capture_ok",
        linear_team_key: "P13115",
        default_branch: "main",
        clone_path: "/tmp/repos/capture-13115",
        linear_state_ids: %{"triage" => "st_triage_ok"},
        linear_workspace: %{
          name: "Capture Workspace 13115",
          external_id: "lin_ws_capture_13115",
          token: "lin_api_token_capture_13115",
          webhook_secret: "whsec_capture_13115"
        },
        active: true
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_capture_8",
        login: "capture_user_8",
        email: "capture_user_8@example.com",
        admin: true
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_capture_ok",
              "identifier" => "CAP-101",
              "title" => "Capture via LiveView",
              "description" => "Multiline\nbody",
              "state" => %{"id" => "st_triage_ok", "name" => "Triage", "type" => "triage"},
              "branchName" => "cap-101-branch",
              "url" => "https://linear.app/issue/CAP-101"
            }
          }
        }
      })
    end)

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues")

    view |> element("#global-capture-idea-button") |> render_click()

    view
    |> form("#capture-issue-form", %{
      "title" => "Capture via LiveView",
      "description" => "Multiline\nbody",
      "project_id" => project.id,
      "priority" => "high"
    })
    |> render_submit()

    refute has_element?(view, "#capture-idea-dialog")

    assert %Issue{project_id: ^project_id, identifier: "CAP-101", title: "Capture via LiveView", priority: :high} =
             Repo.get_by(Issue, external_id: "lin_capture_ok")

    view |> element("#global-capture-idea-button") |> render_click()
    assert has_element?(view, "#capture-title-input[value='']")
  end

  test "submit keeps the dialog open with the values and shows the error when creating fails", %{conn: conn} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Capture Project 13117",
        github_repo: "org/capture-13117",
        github_installation_id: 13_117,
        linear_team_id: "team_capture_err",
        linear_team_key: "P13117",
        default_branch: "main",
        clone_path: "/tmp/repos/capture-13117",
        linear_state_ids: %{"triage" => "st_triage_err"},
        linear_workspace: %{
          name: "Capture Workspace 13117",
          external_id: "lin_ws_capture_13117",
          token: "lin_api_token_capture_13117",
          webhook_secret: "whsec_capture_13117"
        },
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

    expect(Rail.Issues, :create_issue, fn _project, %{title: "Critical production defect", priority: :urgent} ->
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

    expect(Rail.Issues, :create_issue, fn _project, _attrs -> {:error, "Direct string failure"} end)

    render_submit(element(view, "#capture-issue-form"), %{
      "title" => "Testing string error",
      "project_id" => project.id,
      "priority" => "medium"
    })

    assert has_element?(view, "#capture-error-banner", "Direct string failure")

    expect(Rail.Issues, :create_issue, fn _project, _attrs -> {:error, :not_authorized} end)

    render_submit(element(view, "#capture-issue-form"), %{
      "title" => "Testing atom error",
      "project_id" => project.id,
      "priority" => "medium"
    })

    assert has_element?(view, "#capture-error-banner", ":not_authorized")
  end
end
