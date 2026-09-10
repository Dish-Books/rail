defmodule RailWeb.IssuesLiveTest do
  use RailWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock
  alias RailWeb.Components.ArchiveIssueModal
  alias RailWeb.Components.IssueCard
  alias RailWeb.Components.IssueEditorModal
  alias RailWeb.IssuesLive

  test "redirects unauthenticated user to /auth/github", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/github"}}} = live(conn, ~p"/issues")
  end

  test "renders Issues view and navigation rail with active Issues destination", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)

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
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id, name: project_name}} =
             Projects.create_project(scope, %{
               name: "Issues Project",
               github_repo: "example/issues-project",
               github_installation_id: 601,
               linear_team_id: "t_iss",
               linear_team_key: "ISS",
               clone_path: "/tmp/issues-project",
               active: true
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
    {authed_conn, _user} = log_in_test_user(conn)

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
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Demo Project",
               github_repo: "example/demo-project",
               github_installation_id: 701,
               linear_team_id: "t_demo",
               linear_team_key: "DEMO",
               clone_path: "/tmp/demo-project",
               active: true
             })

    issue =
      create_test_issue(%{
        project_id: project_id,
        identifier: "DEMO-101",
        title: "Deduplicated title",
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

    assert has_element?(view, "#bring-local-#{issue.id}", "Bring local")
    assert has_element?(view, "#archive-issue-#{issue.id}")
  end

  test "filters by priority chips and updates chip counts", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Priority Project",
               github_repo: "example/priority-project",
               github_installation_id: 702,
               linear_team_id: "t_prio",
               linear_team_key: "PRIO",
               clone_path: "/tmp/priority-project",
               active: true
             })

    issue_urgent =
      create_test_issue(%{
        project_id: project_id,
        identifier: "PRIO-1",
        title: "Urgent issue",
        priority: :urgent,
        state: :backlog
      })

    issue_high_1 =
      create_test_issue(%{
        project_id: project_id,
        identifier: "PRIO-2",
        title: "High issue 1",
        priority: :high,
        state: :backlog
      })

    issue_high_2 =
      create_test_issue(%{
        project_id: project_id,
        identifier: "PRIO-3",
        title: "High issue 2",
        priority: :high,
        state: :backlog
      })

    issue_low =
      create_test_issue(%{
        project_id: project_id,
        identifier: "PRIO-4",
        title: "Low issue",
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
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Finished Project",
               github_repo: "example/finished-project",
               github_installation_id: 703,
               linear_team_id: "t_fin",
               linear_team_key: "FIN",
               clone_path: "/tmp/finished-project",
               active: true
             })

    active_issue =
      create_test_issue(%{
        project_id: project_id,
        identifier: "FIN-1",
        title: "Active task",
        state: :in_progress
      })

    done_issue =
      create_test_issue(%{
        project_id: project_id,
        identifier: "FIN-2",
        title: "Done task",
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
    refute has_element?(view, "#bring-local-#{done_issue.id}")
    refute has_element?(view, "#task-link-#{done_issue.id}")

    # Toggle show finished off
    view |> element("#issues-show-finished") |> render_click()
    assert has_element?(view, "#issue-card-#{active_issue.id}")
    refute has_element?(view, "#issue-card-#{done_issue.id}")
  end

  test "Bring local button creates task and updates card to show stage link", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Bring Local Project",
               github_repo: "example/bring-local",
               github_installation_id: 704,
               linear_workspace_id: ws_id,
               linear_team_id: "t_bl",
               linear_team_key: "BL",
               linear_state_ids: %{"in_progress" => "st_in_prog_bl"},
               clone_path: "/tmp/bring-local-proj",
               active: true
             })

    issue =
      create_test_issue(%{
        project_id: project_id,
        external_id: "lin_bl_1",
        identifier: "BL-10",
        title: "Bring local feature",
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
    assert has_element?(view, "#bring-local-#{issue.id}")

    view |> element("#bring-local-#{issue.id}") |> render_click()

    # Now task link is displayed instead of bring local
    refute has_element?(view, "#bring-local-#{issue.id}")
    assert has_element?(view, "#task-link-#{issue.id}")

    # Clicking nonexistent issue bring_local does not crash
    render_click(view, "bring_local", %{"issue_id" => "iss_nonexistent"})
  end

  test "opens issue editor modal, updates attributes, and saves changes", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Editor Project",
               github_repo: "example/editor-proj",
               github_installation_id: 705,
               linear_workspace_id: ws_id,
               linear_team_id: "t_ed",
               linear_team_key: "ED",
               clone_path: "/tmp/editor-proj",
               active: true
             })

    issue =
      create_test_issue(%{
        project_id: project_id,
        external_id: "lin_ed_1",
        identifier: "ED-50",
        title: "Initial title",
        description: "Initial description",
        priority: :low,
        state: :triage
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
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Archive Project",
               github_repo: "example/archive-proj",
               github_installation_id: 706,
               linear_workspace_id: ws_id,
               linear_team_id: "t_arc",
               linear_team_key: "ARC",
               linear_state_ids: %{"canceled" => "st_canceled_arc"},
               clone_path: "/tmp/archive-proj",
               active: true
             })

    issue =
      create_test_issue(%{
        project_id: project_id,
        external_id: "lin_arc_view_1",
        identifier: "ARC-99",
        title: "Issue to archive",
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
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Sync Project",
               github_repo: "example/sync-proj",
               github_installation_id: 707,
               linear_workspace_id: ws_id,
               linear_team_id: "t_sync",
               linear_team_key: "SYNC",
               clone_path: "/tmp/sync-proj",
               active: true
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

  test "reloads on PubSub pipeline_changed and live_sync messages", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "PubSub Project",
               github_repo: "example/pubsub-proj",
               github_installation_id: 708,
               linear_team_id: "t_ps",
               linear_team_key: "PS",
               clone_path: "/tmp/pubsub-proj",
               active: true
             })

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    issue =
      create_test_issue(%{
        project_id: project_id,
        identifier: "PS-1",
        title: "Pubsub created issue",
        state: :backlog
      })

    refute has_element?(view, "#issue-card-#{issue.id}")

    send(view.pid, :pipeline_changed)
    assert has_element?(view, "#issue-card-#{issue.id}")

    send(view.pid, %{event: "pipeline_changed"})
    assert has_element?(view, "#issue-card-#{issue.id}")

    send(view.pid, {:live_sync, %{}})
    assert has_element?(view, "#issue-card-#{issue.id}")

    send(view.pid, :unknown_info)
    assert has_element?(view, "#issue-card-#{issue.id}")
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
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: p_id, name: p_name}} =
             Projects.create_project(scope, %{
               name: "With Key Project",
               github_repo: "example/with-key",
               github_installation_id: 801,
               linear_team_id: "t_key",
               linear_team_key: "KEY",
               clone_path: "/tmp/with-key",
               active: true
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
