defmodule RailWeb.IssuesLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope
  alias Rail.Users
  alias RailTest.Mocks.Linear, as: LinearMock
  alias RailWeb.Components.ArchiveIssueModal
  alias RailWeb.Components.IssueCard
  alias RailWeb.Components.IssueEditorModal
  alias RailWeb.IssuesLive

  test "redirects unauthenticated user to /auth/github", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/github"}}} = live(conn, ~p"/issues")
  end

  test "renders Issues view and navigation rail with active Issues destination", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_1",
        login: "issues_live_user_1",
        email: "issues_live_user_1@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    assert has_element?(view, "#issues-view")
    assert has_element?(view, "#issues-title", "Issues")
    assert has_element?(view, "#issues-subtitle", "Linear issues across all projects")
    assert has_element?(view, "#sync-issues-button", "Sync Issues")
    assert has_element?(view, "#new-issue-button", "New Issue")

    # Nav rail checks
    assert has_element?(view, "#navigation-rail")
    assert has_element?(view, "#nav-overview[data-active='false']")
    assert has_element?(view, "#nav-issues[data-active='true']")
    assert has_element?(view, "#nav-settings[data-active='false']")

    # Top app bar checks
    assert has_element?(view, "#top-app-bar")
    assert has_element?(view, "#section-title", "Issues")
  end

  test "handles ?project=<id> param and updates subtitle and switcher", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_2",
        login: "issues_live_user_2",
        email: "issues_live_user_2@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Issues Live Workspace",
        external_id: "lin_ws_issues_live",
        token: "lin_api_token_issues_live",
        webhook_secret: "whsec_issues_live"
      })

    assert {:ok, %Project{id: project_id, name: project_name}} =
             Projects.create_project(scope, %{
               name: "Issues Project",
               github_repo: "example/issues-project",
               github_installation_id: 601,
               linear_team_id: "t_iss",
               linear_team_key: "ISS",
               default_branch: "main",
               clone_path: "/tmp/issues-project",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues?project=#{project_id}")
    assert has_element?(view, "#selected-project-name", project_name)
    assert has_element?(view, "#issues-subtitle", "Linear issues in ISS (#{project_name})")

    # Patch without project
    view |> element("#project-switcher-button") |> render_click()
    view |> element("#project-option-all") |> render_click()

    assert_patched(view, ~p"/issues")
    assert has_element?(view, "#selected-project-name", "All projects")
    assert has_element?(view, "#issues-subtitle", "Linear issues across all projects")
  end

  test "renders empty state when there are no issues", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_3",
        login: "issues_live_user_3",
        email: "issues_live_user_3@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    assert has_element?(view, "#issues-empty-state")
    assert has_element?(view, "[data-qa='empty-state-title']", "No issues in this view")
    assert has_element?(view, "#add-first-issue-button", "Add first issue")

    # Clicking Add first issue opens new issue modal via NavHook
    view |> element("#add-first-issue-button") |> render_click()
    assert has_element?(view, "#new-issue-modal")
  end

  test "renders issue cards with all attributes, badges, body deduplication, and worktree", %{
    conn: conn
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_4",
        login: "issues_live_user_4",
        email: "issues_live_user_4@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Issues Live Workspace",
        external_id: "lin_ws_issues_live",
        token: "lin_api_token_issues_live",
        webhook_secret: "whsec_issues_live"
      })

    assert {:ok, %Project{id: _project_id} = project} =
             Projects.create_project(scope, %{
               name: "Demo Project",
               github_repo: "example/demo-project",
               github_installation_id: 701,
               linear_team_id: "t_demo",
               linear_team_key: "DEMO",
               default_branch: "main",
               clone_path: "/tmp/demo-project",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_issues_live_13201",
      "identifier" => "DEMO-101",
      "title" => "Deduplicated title"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Deduplicated title")

    LinearMock.mock_update_issue_success(%{"id" => "lin_issues_live_13201"})

    LinearMock.mock_update_issue_success(%{"id" => issue.external_id})

    {:ok, issue} =
      Issues.update_issue(system_scope(), issue, %{
        description: "Deduplicated title\nDetailed explanation of the issue.",
        priority: :urgent,
        state: :in_progress,
        branch_name: "feat-demo-101",
        url: "https://linear.app/demo/issue/DEMO-101"
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    assert has_element?(view, "#issue-card-#{issue.id}")
    assert has_element?(view, "#issue-card-#{issue.id} [data-qa='issue-identifier']", "DEMO-101")
    assert has_element?(view, "#issue-card-#{issue.id} [data-qa='project-badge']", "DEMO")
    assert has_element?(view, "#issue-card-#{issue.id} [data-qa='issue-external-link']")
    assert has_element?(view, "#issue-card-#{issue.id} [data-qa='issue-title']", "Deduplicated title")
    assert has_element?(view, "#issue-card-#{issue.id} [data-qa='issue-priority-badge']", "Urgent")
    assert has_element?(view, "#issue-card-#{issue.id} [data-qa='issue-status-badge']", "In Progress")
    assert has_element?(view, "#issue-card-#{issue.id} [data-qa='issue-body']", "Detailed explanation of the issue.")

    assert has_element?(
             view,
             "#issue-card-#{issue.id} [data-qa='issue-worktree']",
             "Dedicated Worktree: .worktrees/feat-demo-101"
           )

    assert has_element?(view, "#start-product-run-#{issue.id}", "Start")
    assert has_element?(view, "#archive-issue-#{issue.id}")
  end

  test "filters by priority chips and updates chip counts", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_5",
        login: "issues_live_user_5",
        email: "issues_live_user_5@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Issues Live Workspace",
        external_id: "lin_ws_issues_live",
        token: "lin_api_token_issues_live",
        webhook_secret: "whsec_issues_live"
      })

    assert {:ok, %Project{id: _project_id} = project} =
             Projects.create_project(scope, %{
               name: "Priority Project",
               github_repo: "example/priority-project",
               github_installation_id: 702,
               linear_team_id: "t_prio",
               linear_team_key: "PRIO",
               default_branch: "main",
               clone_path: "/tmp/priority-project",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_issues_live_13202",
      "identifier" => "PRIO-1",
      "title" => "Urgent issue"
    })

    {:ok, issue_urgent} = Issues.capture_issue(system_scope(), project, "Urgent issue")

    {:ok, issue_urgent} =
      Issues.update_issue(system_scope(), issue_urgent, %{
        priority: :urgent,
        state: :backlog
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_issues_live_13203",
      "identifier" => "PRIO-2",
      "title" => "High issue 1"
    })

    {:ok, issue_high_1} = Issues.capture_issue(system_scope(), project, "High issue 1")

    {:ok, issue_high_1} =
      Issues.update_issue(system_scope(), issue_high_1, %{
        priority: :high,
        state: :backlog
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_issues_live_13204",
      "identifier" => "PRIO-3",
      "title" => "High issue 2"
    })

    {:ok, issue_high_2} = Issues.capture_issue(system_scope(), project, "High issue 2")

    {:ok, issue_high_2} =
      Issues.update_issue(system_scope(), issue_high_2, %{
        priority: :high,
        state: :backlog
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_issues_live_13205",
      "identifier" => "PRIO-4",
      "title" => "Low issue"
    })

    {:ok, issue_low} = Issues.capture_issue(system_scope(), project, "Low issue")

    {:ok, issue_low} =
      Issues.update_issue(system_scope(), issue_low, %{
        priority: :low,
        state: :backlog
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    # Check chip counts
    assert has_element?(view, "#filter-priority-all", "All (4)")
    assert has_element?(view, "#filter-priority-urgent", "Urgent (1)")
    assert has_element?(view, "#filter-priority-high", "High (2)")
    assert has_element?(view, "#filter-priority-medium", "Medium (0)")
    assert has_element?(view, "#filter-priority-low", "Low (1)")

    # All 4 cards visible
    assert has_element?(view, "#issue-card-#{issue_urgent.id}")
    assert has_element?(view, "#issue-card-#{issue_high_1.id}")
    assert has_element?(view, "#issue-card-#{issue_high_2.id}")
    assert has_element?(view, "#issue-card-#{issue_low.id}")

    # Select High filter
    view |> element("#filter-priority-high") |> render_click()
    refute has_element?(view, "#issue-card-#{issue_urgent.id}")
    assert has_element?(view, "#issue-card-#{issue_high_1.id}")
    assert has_element?(view, "#issue-card-#{issue_high_2.id}")
    refute has_element?(view, "#issue-card-#{issue_low.id}")

    # Clicking High again toggles off
    view |> element("#filter-priority-high") |> render_click()
    assert has_element?(view, "#issue-card-#{issue_urgent.id}")
    assert has_element?(view, "#issue-card-#{issue_high_1.id}")

    # Select Urgent filter
    view |> element("#filter-priority-urgent") |> render_click()
    assert has_element?(view, "#issue-card-#{issue_urgent.id}")
    refute has_element?(view, "#issue-card-#{issue_high_1.id}")

    # Click All chip resets
    view |> element("#filter-priority-all") |> render_click()
    assert has_element?(view, "#issue-card-#{issue_urgent.id}")
    assert has_element?(view, "#issue-card-#{issue_high_1.id}")

    # Priority with unknown string
    view |> element("#filter-priority-all") |> render_click(%{"priority" => "invalid_prio"})
    assert has_element?(view, "#issue-card-#{issue_urgent.id}")
  end

  test "toggles Show finished filter chip", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_6",
        login: "issues_live_user_6",
        email: "issues_live_user_6@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Issues Live Workspace",
        external_id: "lin_ws_issues_live",
        token: "lin_api_token_issues_live",
        webhook_secret: "whsec_issues_live"
      })

    assert {:ok, %Project{id: _project_id} = project} =
             Projects.create_project(scope, %{
               name: "Finished Project",
               github_repo: "example/finished-project",
               github_installation_id: 703,
               linear_team_id: "t_fin",
               linear_team_key: "FIN",
               default_branch: "main",
               clone_path: "/tmp/finished-project",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_issues_live_13206",
      "identifier" => "FIN-1",
      "title" => "Active task"
    })

    {:ok, active_issue} = Issues.capture_issue(system_scope(), project, "Active task")

    LinearMock.mock_update_issue_success(%{"id" => active_issue.external_id})

    {:ok, active_issue} =
      Issues.update_issue(system_scope(), active_issue, %{
        state: :in_progress
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_issues_live_13207",
      "identifier" => "FIN-2",
      "title" => "Done task"
    })

    {:ok, done_issue} = Issues.capture_issue(system_scope(), project, "Done task")

    {:ok, done_issue} =
      Issues.update_issue(system_scope(), done_issue, %{
        state: :done
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    # By default, show_finished is false -> only active_issue visible
    assert has_element?(view, "#issue-card-#{active_issue.id}")
    refute has_element?(view, "#issue-card-#{done_issue.id}")
    assert has_element?(view, "#filter-priority-all", "All (1)")

    # Toggle show finished on
    view |> element("#issues-show-finished") |> render_click()
    assert has_element?(view, "#issue-card-#{active_issue.id}")
    assert has_element?(view, "#issue-card-#{done_issue.id}")
    assert has_element?(view, "#filter-priority-all", "All (2)")

    # Finished issue has no Bring local button and no task link
    refute has_element?(view, "#start-product-run-#{done_issue.id}")
    refute has_element?(view, "#task-link-#{done_issue.id}")

    # Toggle show finished off
    view |> element("#issues-show-finished") |> render_click()
    assert has_element?(view, "#issue-card-#{active_issue.id}")
    refute has_element?(view, "#issue-card-#{done_issue.id}")
  end

  test "Bring local button creates task and updates card to show stage link", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_7",
        login: "issues_live_user_7",
        email: "issues_live_user_7@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    {:ok, %LinearWorkspace{id: ws_id}} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Issues Live Workspace 13212",
        external_id: "lin_ws_issues_live_13212",
        token: "lin_api_token_issues_live_13212",
        webhook_secret: "whsec_issues_live_13212"
      })

    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Issues Live Workspace",
        external_id: "lin_ws_issues_live",
        token: "lin_api_token_issues_live",
        webhook_secret: "whsec_issues_live"
      })

    assert {:ok, %Project{id: _project_id} = project} =
             Projects.create_project(scope, %{
               name: "Bring Local Project",
               github_repo: "example/bring-local",
               github_installation_id: 704,
               linear_workspace_id: ws_id,
               linear_team_id: "t_bl",
               linear_team_key: "BL",
               linear_state_ids: %{"in_progress" => "st_in_prog_bl"},
               default_branch: "main",
               clone_path: "/tmp/bring-local-proj",
               active: true
             })

    LinearMock.mock_create_issue_success(%{"id" => "lin_bl_1", "identifier" => "BL-10", "title" => "Bring local feature"})

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Bring local feature")

    {:ok, issue} =
      Issues.update_issue(system_scope(), issue, %{
        state: :backlog
      })

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_bl_1",
      "identifier" => "BL-10",
      "title" => "Bring local feature",
      "description" => issue.description,
      "state" => %{"id" => "st_in_prog_bl", "name" => "In Progress", "type" => "started"},
      "branchName" => nil,
      "url" => issue.url,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-02T12:00:00.000Z"
    })

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")
    assert has_element?(view, "#start-product-run-#{issue.id}")

    view |> element("#start-product-run-#{issue.id}") |> render_click()

    # Now task link is displayed instead of bring local
    refute has_element?(view, "#start-product-run-#{issue.id}")
    assert has_element?(view, "#task-link-#{issue.id}")

    # Clicking start on a nonexistent issue does not crash
    render_click(view, "start_product_run", %{"issue_id" => "iss_nonexistent"})
  end

  test "opens issue editor modal, updates attributes, and saves changes", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_8",
        login: "issues_live_user_8",
        email: "issues_live_user_8@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    {:ok, %LinearWorkspace{id: ws_id}} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Issues Live Workspace 13213",
        external_id: "lin_ws_issues_live_13213",
        token: "lin_api_token_issues_live_13213",
        webhook_secret: "whsec_issues_live_13213"
      })

    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Issues Live Workspace",
        external_id: "lin_ws_issues_live",
        token: "lin_api_token_issues_live",
        webhook_secret: "whsec_issues_live"
      })

    assert {:ok, %Project{id: _project_id} = project} =
             Projects.create_project(scope, %{
               name: "Editor Project",
               github_repo: "example/editor-proj",
               github_installation_id: 705,
               linear_workspace_id: ws_id,
               linear_team_id: "t_ed",
               linear_team_key: "ED",
               default_branch: "main",
               clone_path: "/tmp/editor-proj",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    LinearMock.mock_create_issue_success(%{"id" => "lin_ed_1", "identifier" => "ED-50", "title" => "Initial title"})

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Initial title")

    LinearMock.mock_update_issue_success(%{"id" => "lin_ed_1"})

    {:ok, issue} =
      Issues.update_issue(system_scope(), issue, %{
        description: "Initial description",
        priority: :low
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    refute has_element?(view, "#issue-editor-dialog")

    # Click card to open editor
    view |> element("#issue-card-#{issue.id}") |> render_click()
    assert has_element?(view, "#issue-editor-dialog")
    assert has_element?(view, "#editor-dialog-title", "Edit ED-50")

    # Form change event (noop)
    view |> element("#issue-editor-form") |> render_change(%{"title" => "Typing..."})

    # Close and reopen editor
    view |> element("#close-editor-button") |> render_click()
    refute has_element?(view, "#issue-editor-dialog")

    view |> element("#issue-card-#{issue.id}") |> render_click()
    assert has_element?(view, "#issue-editor-dialog")

    view |> element("#editor-cancel-button") |> render_click()
    refute has_element?(view, "#issue-editor-dialog")

    # Open again to submit
    view |> element("#issue-card-#{issue.id}") |> render_click()

    # Empty title submit is rejected without crash
    view |> element("#issue-editor-form") |> render_submit(%{"issue_id" => issue.id, "title" => "   "})
    assert has_element?(view, "#issue-editor-dialog")

    # Mock Linear update for valid submit
    LinearMock.mock_update_issue_success(%{
      "id" => "lin_ed_1",
      "identifier" => "ED-50",
      "title" => "Updated title",
      "description" => "Updated description",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => issue.url,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-02T12:00:00.000Z"
    })

    view
    |> element("#issue-editor-form")
    |> render_submit(%{
      "issue_id" => issue.id,
      "title" => "Updated title",
      "description" => "Updated description",
      "priority" => "urgent",
      "state" => "backlog"
    })

    refute has_element?(view, "#issue-editor-dialog")
    assert has_element?(view, "#issue-card-#{issue.id} [data-qa='issue-title']", "Updated title")
    assert has_element?(view, "#issue-card-#{issue.id} [data-qa='issue-priority-badge']", "Urgent")

    # Submitting for nonexistent issue does not crash
    render_submit(view, "save_issue", %{"issue_id" => "iss_nonexistent", "title" => "Test"})
    render_click(view, "open_editor", %{"issue_id" => "iss_nonexistent"})
  end

  test "opens archive confirmation modal and confirms archive", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_9",
        login: "issues_live_user_9",
        email: "issues_live_user_9@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    {:ok, %LinearWorkspace{id: ws_id}} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Issues Live Workspace 13214",
        external_id: "lin_ws_issues_live_13214",
        token: "lin_api_token_issues_live_13214",
        webhook_secret: "whsec_issues_live_13214"
      })

    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Issues Live Workspace",
        external_id: "lin_ws_issues_live",
        token: "lin_api_token_issues_live",
        webhook_secret: "whsec_issues_live"
      })

    assert {:ok, %Project{id: _project_id} = project} =
             Projects.create_project(scope, %{
               name: "Archive Project",
               github_repo: "example/archive-proj",
               github_installation_id: 706,
               linear_workspace_id: ws_id,
               linear_team_id: "t_arc",
               linear_team_key: "ARC",
               linear_state_ids: %{"canceled" => "st_canceled_arc"},
               default_branch: "main",
               clone_path: "/tmp/archive-proj",
               active: true
             })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_arc_view_1",
      "identifier" => "ARC-99",
      "title" => "Issue to archive"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Issue to archive")

    {:ok, issue} =
      Issues.update_issue(system_scope(), issue, %{
        state: :backlog
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    refute has_element?(view, "#archive-issue-dialog")

    # Open archive modal from card
    view |> element("#archive-issue-#{issue.id}") |> render_click()
    assert has_element?(view, "#archive-issue-dialog")
    assert has_element?(view, "#archive-modal-title", "Archive ARC-99?")

    assert has_element?(
             view,
             "#archive-modal-body",
             "This archives \"Issue to archive\" and marks it as canceled in Linear."
           )

    # Cancel archive
    view |> element("#cancel-archive-button") |> render_click()
    refute has_element?(view, "#archive-issue-dialog")

    # Open archive modal from editor
    view |> element("#issue-card-#{issue.id}") |> render_click()
    assert has_element?(view, "#issue-editor-dialog")
    view |> element("#editor-archive-button") |> render_click()
    assert has_element?(view, "#archive-issue-dialog")

    # Confirm archive
    LinearMock.mock_update_issue_success(%{
      "id" => "lin_arc_view_1",
      "identifier" => "ARC-99",
      "title" => "Issue to archive",
      "description" => issue.description,
      "state" => %{"id" => "st_canceled_arc", "name" => "Canceled", "type" => "canceled"},
      "branchName" => nil,
      "url" => issue.url,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-02T12:00:00.000Z"
    })

    view |> element("#confirm-archive-button") |> render_click()

    refute has_element?(view, "#archive-issue-dialog")
    refute has_element?(view, "#issue-editor-dialog")
    # Finished issue is hidden since show_finished is false
    refute has_element?(view, "#issue-card-#{issue.id}")

    # Confirm archive on nonexistent issue
    render_click(view, "confirm_archive", %{"issue_id" => "iss_nonexistent"})
    render_click(view, "open_archive", %{"issue_id" => "iss_nonexistent"})
  end

  test "sync_issues button triggers sync on current project or all projects", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_10",
        login: "issues_live_user_10",
        email: "issues_live_user_10@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    {:ok, %LinearWorkspace{id: ws_id}} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Issues Live Workspace 13215",
        external_id: "lin_ws_issues_live_13215",
        token: "lin_api_token_issues_live_13215",
        webhook_secret: "whsec_issues_live_13215"
      })

    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Issues Live Workspace",
        external_id: "lin_ws_issues_live",
        token: "lin_api_token_issues_live",
        webhook_secret: "whsec_issues_live"
      })

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Sync Project",
               github_repo: "example/sync-proj",
               github_installation_id: 707,
               linear_workspace_id: ws_id,
               linear_team_id: "t_sync",
               linear_team_key: "SYNC",
               default_branch: "main",
               clone_path: "/tmp/sync-proj",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    LinearMock.mock_issues_success([])

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues?project=#{project_id}")

    view |> element("#sync-issues-button") |> render_click()
    assert has_element?(view, "#sync-issues-button", "Sync Issues")

    # Unfiltered sync
    LinearMock.mock_issues_success([])
    assert {:ok, view_all, _html} = live(authed_conn, ~p"/issues")
    view_all |> element("#sync-issues-button") |> render_click()
    assert has_element?(view_all, "#sync-issues-button", "Sync Issues")
  end

  test "component helper functions cover all edge cases", %{conn: _conn} do
    # card_body_for edge cases
    assert IssueCard.card_body_for(%{title: "Test", description: ""}) == ""
    assert IssueCard.card_body_for(%{title: "Test", description: nil}) == ""
    assert IssueCard.card_body_for(%{title: "Test", description: "Test"}) == ""
    assert IssueCard.card_body_for(%{title: "Test", description: "Test\nSecond line"}) == "Second line"
    assert IssueCard.card_body_for(%{title: "Other", description: "Hello world"}) == "Hello world"

    # worktree_name edge cases
    assert IssueCard.worktree_name(%{branch_name: "custom-branch", identifier: "ENG-1", id: "1"}) == "custom-branch"
    assert IssueCard.worktree_name(%{branch_name: nil, identifier: "ENG/FEATURE 1", id: "1"}) == "eng-feature-1"
    assert IssueCard.worktree_name(%{branch_name: "", identifier: "", id: "99"}) == "issue-99"

    # priority_label & status_label edge cases
    assert IssueCard.priority_label(:urgent) == "Urgent"
    assert IssueCard.priority_label(nil) == "Medium"
    assert IssueCard.status_label(:in_progress) == "In Progress"
    assert IssueCard.status_label(nil) == "Triage"

    # render_component checks
    rendered =
      render_component(&IssueCard.issue_card/1,
        issue: %{
          id: "iss_mock_1",
          identifier: "MOCK-1",
          project: %{name: "P1", linear_team_key: "P1"},
          url: nil,
          title: "Mock Title",
          description: "Mock Description",
          priority: :low,
          state: :done,
          branch_name: nil
        },
        task: nil
      )

    assert rendered =~ "MOCK-1"
    assert rendered =~ "Mock Title"

    # With task
    rendered_with_task =
      render_component(&IssueCard.issue_card/1,
        issue: %{
          id: "iss_mock_2",
          identifier: "MOCK-2",
          project: nil,
          url: "https://linear.app/mock-2",
          title: "Mock Title 2",
          description: nil,
          priority: nil,
          state: :in_progress,
          branch_name: "feat-mock-2"
        },
        task: %Task{
          id: "tsk_mock_2",
          stage: :engineer,
          stage_state: :running,
          issue: nil
        }
      )

    assert rendered_with_task =~ "Engineer running"

    # IssueEditorModal rendered directly
    editor_rendered =
      render_component(&IssueEditorModal.issue_editor_modal/1,
        issue: %{
          id: "iss_mock_3",
          identifier: "MOCK-3",
          url: "https://linear.app/mock-3",
          title: "Editor test",
          description: "Body",
          priority: :high,
          state: :triage
        },
        visible: true
      )

    assert editor_rendered =~ "Edit MOCK-3"
    assert editor_rendered =~ "Editor test"

    assert render_component(&IssueEditorModal.issue_editor_modal/1, issue: nil, visible: false) == ""

    # ArchiveIssueModal rendered directly
    archive_rendered =
      render_component(&ArchiveIssueModal.archive_issue_modal/1,
        issue: %{
          id: "iss_mock_4",
          identifier: "MOCK-4",
          title: "To archive"
        },
        visible: true
      )

    assert archive_rendered =~ "Archive MOCK-4?"
    assert archive_rendered =~ "To archive"

    assert render_component(&ArchiveIssueModal.archive_issue_modal/1, issue: nil, visible: false) == ""
  end

  test "handles subtitle for projects with and without team keys", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_12",
        login: "issues_live_user_12",
        email: "issues_live_user_12@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Issues Live Workspace",
        external_id: "lin_ws_issues_live",
        token: "lin_api_token_issues_live",
        webhook_secret: "whsec_issues_live"
      })

    assert {:ok, %Project{id: p_id, name: p_name}} =
             Projects.create_project(scope, %{
               name: "With Key Project",
               github_repo: "example/with-key",
               github_installation_id: 801,
               linear_team_id: "t_key",
               linear_team_key: "KEY",
               default_branch: "main",
               clone_path: "/tmp/with-key",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues?project=#{p_id}")
    assert has_element?(view, "#issues-subtitle", "Linear issues in KEY (#{p_name})")

    # Nonexistent project ID
    assert {:ok, view_bad, _html} = live(authed_conn, ~p"/issues?project=prj_nonexistent")
    assert has_element?(view_bad, "#issues-subtitle", "Linear issues across all projects")

    # Direct unit tests of subtitle_for
    assert IssuesLive.subtitle_for(nil) == "Linear issues across all projects"
    assert IssuesLive.subtitle_for(%{linear_team_key: "ENG", name: "Rail"}) == "Linear issues in ENG (Rail)"
    assert IssuesLive.subtitle_for(%{linear_team_key: "", name: "Rail"}) == "Linear issues for Rail"
    assert IssuesLive.subtitle_for(%{linear_team_key: nil, name: "Rail"}) == "Linear issues for Rail"
    assert IssuesLive.subtitle_for(%{}) == "No target repository set • Issues live in Linear; set one in Settings"
    assert IssuesLive.subtitle_for("other") == "No target repository set • Issues live in Linear; set one in Settings"
  end
end
