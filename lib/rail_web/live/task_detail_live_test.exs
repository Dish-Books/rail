defmodule RailWeb.TaskDetailLiveTest do
  use RailWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.Socket
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Runs
  alias Rail.Scope

  test "redirects unauthenticated user to /auth/github", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/github"}}} = live(conn, ~p"/tasks/tsk_dummy")
  end

  test "renders task cleaned-up state when task is not found", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/nonexistent-123")

    assert has_element?(view, "#task-detail-view")
    assert has_element?(view, "#task-detail-title", "Task")
    assert has_element?(view, "#task-cleaned-up")
    assert has_element?(view, "#task-cleaned-up", "This task has been cleaned up.")
  end

  test "renders task details with header, project badge, tabs, stepper, metadata wrap, and ticket", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Detail Project",
               github_repo: "example/detail-project",
               github_installation_id: 603,
               linear_team_id: "t_det",
               linear_team_key: "DET",
               clone_path: "/tmp/detail-project",
               active: true
             })

    issue =
      create_test_issue(%{
        project_id: project_id,
        identifier: "DET-42",
        branch_name: "feature-branch"
      })

    task =
      create_test_task(%{
        project_id: project_id,
        issue_id: issue.id,
        title: "Implement Login Flow",
        description: "Must handle OAuth callbacks cleanly",
        stage: :engineer,
        stage_state: :running,
        worktree_name: "login-flow",
        pr_number: 101,
        pr_url: "https://github.com/example/detail-project/pull/101"
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")

    # Header & Badge
    assert has_element?(view, "#task-detail-view")
    assert has_element?(view, "#task-detail-title", "Implement Login Flow")
    assert has_element?(view, "[data-qa='project-badge']", "DET")

    # 4 Tabs in exact order
    assert has_element?(view, "#tab-overview", "Overview")
    assert has_element?(view, "#tab-plan", "Plan")
    assert has_element?(view, "#tab-conversation", "Conversation")
    assert has_element?(view, "#tab-diff", "Diff")
    assert has_element?(view, "#tab-overview[data-active='true']")

    # Stage Stepper
    assert has_element?(view, "#stage-stepper")
    assert has_element?(view, "#stage-chip-engineer")

    # Metadata Wrap
    assert has_element?(view, "#task-metadata-wrap")
    assert has_element?(view, "#metadata-status-chip")
    assert has_element?(view, "#meta-branch", "axis/login-flow")
    assert has_element?(view, "#meta-issue", "DET-42")
    assert has_element?(view, "#meta-pr", "PR #101")
    assert has_element?(view, "#meta-priority")

    # Ticket Section on Overview
    assert has_element?(view, "#ticket-section")
    assert has_element?(view, "#ticket-section", "Must handle OAuth callbacks cleanly")

    # No conflict banner or error card by default
    refute has_element?(view, "#conflict-banner")
    refute has_element?(view, "#task-error-card")
  end

  test "switches tabs and displays tab panes", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Tab Switching Project",
               github_repo: "example/tab-project",
               github_installation_id: 605,
               linear_team_id: "t_tab",
               linear_team_key: "TAB",
               clone_path: "/tmp/tab-project",
               active: true
             })

    task =
      create_test_task(%{
        project_id: project_id,
        title: "Tab Switching Task",
        description: "Testing tabs",
        stage: :product,
        stage_state: :running,
        worktree_path: "/tmp/worktree/tab-task"
      })

    create_test_plan(%{
      task_id: task.id,
      content: "## Architectural Plan\n1. Step one\n2. Step two"
    })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")

    # Switch to Plan tab via patch
    assert view |> element("#tab-plan") |> render_click() =~ "Architectural Plan"
    assert_patched(view, ~p"/tasks/#{task.id}?tab=plan")
    assert has_element?(view, "#tab-plan[data-active='true']")
    assert has_element?(view, "#plan-content")
    assert has_element?(view, "#plan-content", "Architectural Plan")

    # Switch to Conversation tab
    view |> element("#tab-conversation") |> render_click()
    assert_patched(view, ~p"/tasks/#{task.id}?tab=conversation")
    assert has_element?(view, "#tab-conversation[data-active='true']")
    assert has_element?(view, "#conversation-empty-state")

    # Switch to Diff tab
    view |> element("#tab-diff") |> render_click()
    assert_patched(view, ~p"/tasks/#{task.id}?tab=diff")
    assert has_element?(view, "#tab-diff[data-active='true']")
    assert has_element?(view, "#tab-diff-pane")
    assert has_element?(view, "#tab-diff-pane", "/tmp/worktree/tab-task")
    assert has_element?(view, "#btn-refresh-diff", "Refresh")

    # Switch back to Overview tab
    view |> element("#tab-overview") |> render_click()
    assert_patched(view, ~p"/tasks/#{task.id}?tab=overview")
    assert has_element?(view, "#tab-overview[data-active='true']")
    assert has_element?(view, "#ticket-section")

    # Trigger switch_tab handle_event directly
    render_hook(view, "switch_tab", %{"tab" => "plan"})
    assert_patched(view, ~p"/tasks/#{task.id}?tab=plan")
  end

  test "renders plan empty state when no plan exists", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "No Plan Project",
               github_repo: "example/no-plan",
               github_installation_id: 606,
               linear_team_id: "t_np",
               linear_team_key: "NP",
               clone_path: "/tmp/no-plan",
               active: true
             })

    task =
      create_test_task(%{
        project_id: project_id,
        title: "No Plan Task",
        description: "Task without plan",
        stage: :product,
        stage_state: :queued
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}?tab=plan")
    assert has_element?(view, "#plan-empty-state")
    assert has_element?(view, "#plan-empty-state", "No plan has been written yet.")
  end

  test "renders diff empty state when worktree_path is nil", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "No Worktree Project",
               github_repo: "example/no-wt",
               github_installation_id: 607,
               linear_team_id: "t_nw",
               linear_team_key: "NW",
               clone_path: "/tmp/no-wt",
               active: true
             })

    task =
      create_test_task(%{
        project_id: project_id,
        title: "No Worktree Task",
        description: "Task without worktree",
        stage: :product,
        stage_state: :queued,
        worktree_path: nil
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}?tab=diff")
    assert has_element?(view, "#diff-empty-state")
    assert has_element?(view, "#diff-empty-state", "This task has no worktree.")
  end

  test "renders conflict banner when task has merge conflicts and not rebasing", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Conflict Project",
               github_repo: "example/conflict",
               github_installation_id: 608,
               linear_team_id: "t_cf",
               linear_team_key: "CF",
               clone_path: "/tmp/conflict",
               active: true
             })

    conflicted_task =
      create_test_task(%{
        project_id: project_id,
        title: "Conflicted Task",
        description: "Merge conflict present",
        stage: :engineer,
        stage_state: :failed,
        mergeability: :conflicting,
        is_rebasing: false,
        pr_number: 42
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{conflicted_task.id}")
    assert has_element?(view, "#conflict-banner")
    assert has_element?(view, "#conflict-banner", "PR #42")

    # When task is rebasing, conflict banner is suppressed
    rebasing_task =
      create_test_task(%{
        project_id: project_id,
        title: "Rebasing Task",
        description: "Actively rebasing",
        stage: :engineer,
        stage_state: :running,
        mergeability: :conflicting,
        is_rebasing: true,
        pr_number: 43
      })

    assert {:ok, rebasing_view, _html} = live(authed_conn, ~p"/tasks/#{rebasing_task.id}")
    refute has_element?(rebasing_view, "#conflict-banner")
  end

  test "renders error card when task has error", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Error Project",
               github_repo: "example/error",
               github_installation_id: 609,
               linear_team_id: "t_err",
               linear_team_key: "ERR",
               clone_path: "/tmp/error",
               active: true
             })

    task =
      create_test_task(%{
        project_id: project_id,
        title: "Error Task",
        description: "Task with error",
        stage: :engineer,
        stage_state: :failed,
        error: "Elixir compilation error in test/dummy_test.exs:10"
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#task-error-card")
    assert has_element?(view, "#task-error-card", "Elixir compilation error")
  end

  test "renders stage outcome when role run output and failure details exist", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Outcome Project",
               github_repo: "example/outcome",
               github_installation_id: 610,
               linear_team_id: "t_out",
               linear_team_key: "OUT",
               clone_path: "/tmp/outcome",
               active: true
             })

    role =
      create_test_role(%{
        project_id: project_id,
        name: "Engineer",
        stage: :engineer
      })

    task =
      create_test_task(%{
        project_id: project_id,
        title: "Outcome Task",
        description: "Task with role run",
        stage: :engineer,
        stage_state: :failed
      })

    now = DateTime.utc_now()

    {:ok, _role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        started_at: now,
        output: "Finished analysis of authentication module.",
        error: "Unit tests failed with exit code 1"
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#stage-outcome")
    assert has_element?(view, "#stage-failure-section")
    assert has_element?(view, "#stage-failure-box", "Unit tests failed with exit code 1")
    assert has_element?(view, "#stage-outcome-section")
    assert has_element?(view, "#stage-outcome-card", "Finished analysis of authentication module.")
  end

  test "skips design stage when project/task does not use design", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "No Design Project",
               github_repo: "example/no-design",
               github_installation_id: 611,
               linear_team_id: "t_nd",
               linear_team_key: "ND",
               clone_path: "/tmp/no-design",
               active: true
             })

    task =
      create_test_task(%{
        project_id: project_id,
        title: "Backend API Task",
        description: "Pure backend work",
        stage: :engineer,
        stage_state: :running
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#stage-stepper")
    assert has_element?(view, "#stage-chip-engineer")
    refute has_element?(view, "#stage-chip-design")
  end

  test "handles PubSub updates and LiveSync messages reactively", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "PubSub Project",
               github_repo: "example/pubsub",
               github_installation_id: 612,
               linear_team_id: "t_ps",
               linear_team_key: "PS",
               clone_path: "/tmp/pubsub",
               active: true
             })

    %Task{id: target_id} =
      create_test_task(%{
        project_id: project_id,
        title: "Initial Title",
        description: "Initial description",
        stage: :product,
        stage_state: :queued
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{target_id}")
    assert has_element?(view, "#task-detail-title", "Initial Title")

    # 1. PubSub :pipeline_changed with matching task_id
    Rail.Repo.update_all(
      from(t in Task, where: t.id == ^target_id),
      set: [title: "Updated via Pipeline Event"]
    )

    send(view.pid, {:pipeline_changed, %{task_id: target_id}})
    assert render(view) =~ "Updated via Pipeline Event"

    # PubSub :pipeline_changed with non-matching task_id is ignored
    send(view.pid, {:pipeline_changed, %{task_id: "tsk_other"}})
    assert render(view) =~ "Updated via Pipeline Event"

    # 2. LiveSync event with atom :id
    Rail.Repo.update_all(
      from(t in Task, where: t.id == ^target_id),
      set: [title: "Updated via LiveSync Atom"]
    )

    send(view.pid, {:livesync, :tasks, "tasks", :update, %{id: target_id}})
    assert render(view) =~ "Updated via LiveSync Atom"

    # 3. LiveSync event with string "id"
    Rail.Repo.update_all(
      from(t in Task, where: t.id == ^target_id),
      set: [title: "Updated via LiveSync String"]
    )

    send(view.pid, {:livesync, :tasks, "tasks", :update, %{"id" => target_id}})
    assert render(view) =~ "Updated via LiveSync String"

    # LiveSync with non-matching or invalid record
    send(view.pid, {:livesync, :tasks, "tasks", :update, %{id: "tsk_other"}})
    send(view.pid, {:livesync, :tasks, "tasks", :update, :not_a_map})
    assert render(view) =~ "Updated via LiveSync String"

    # 4. Direct :task_updated message
    {:ok, updated_task} = Rail.Pipeline.get_task(scope, target_id)
    updated_task = %{updated_task | title: "Directly Updated Task"}
    send(view.pid, {:task_updated, updated_task})
    assert render(view) =~ "Directly Updated Task"

    # Direct :task_updated message with different task id is ignored
    send(view.pid, {:task_updated, %Task{id: "tsk_different", title: "Ignored"}})
    assert render(view) =~ "Directly Updated Task"

    # 5. Unknown message and async handling
    send(view.pid, :some_unknown_info)
    send(view.pid, {:unknown, "message"})
    assert render(view) =~ "Directly Updated Task"
  end

  test "handles ?project=<id> param and project switcher", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id, name: project_name}} =
             Projects.create_project(scope, %{
               name: "Project Switcher Task",
               github_repo: "example/pst",
               github_installation_id: 604,
               linear_team_id: "t_pst",
               linear_team_key: "PST",
               clone_path: "/tmp/pst",
               active: true
             })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/some-task?project=#{project_id}")
    assert has_element?(view, "#selected-project-name", project_name)

    # Patch without project
    view |> element("#project-switcher-button") |> render_click()
    view |> element("#project-option-all") |> render_click()

    assert_patched(view, ~p"/tasks/some-task")
    assert has_element?(view, "#selected-project-name", "All projects")
  end

  test "formats various metadata fallbacks and roles gracefully", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Fallback Project",
               github_repo: "example/fallback",
               github_installation_id: 613,
               linear_team_id: "t_fb",
               linear_team_key: "FB",
               clone_path: "/tmp/fallback",
               active: true
             })

    # Task with issue branch name instead of worktree name, and pr_number without full pr_url
    issue =
      create_test_issue(%{
        project_id: project_id,
        identifier: "FB-99",
        branch_name: "axis/issue-branch",
        priority: :urgent
      })

    task =
      create_test_task(%{
        project_id: project_id,
        issue_id: issue.id,
        title: "Metadata Fallback Task",
        description: "## Ticket\n\nTicket description content\n\n## Implementation Plan\n\nPlan details",
        stage: :architect,
        stage_state: :queued,
        worktree_name: nil,
        pr_number: 55,
        pr_url: nil,
        priority: nil
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#meta-branch", "axis/issue-branch")
    assert has_element?(view, "#meta-issue", "FB-99")
    assert has_element?(view, "#meta-pr", "PR #55")
    assert has_element?(view, "#meta-priority", "Urgent")
    assert has_element?(view, "#ticket-section", "Ticket description content")
  end

  test "exercises LiveView callbacks and edge-case branches", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Edge Case Project",
               github_repo: "example/edge-case",
               github_installation_id: 614,
               linear_team_id: "t_ec",
               linear_team_key: "EC",
               clone_path: "/tmp/edge-case",
               active: true
             })

    issue =
      create_test_issue(%{
        project_id: project_id,
        identifier: "EC-1",
        priority: :high
      })

    %Task{id: task_id} =
      create_test_task(%{
        project_id: project_id,
        issue_id: issue.id,
        title: "Edge Case Task",
        description: "Edge case description",
        stage: :demo,
        stage_state: :running,
        worktree_name: "axis/existing-prefix",
        pr_number: 99,
        pr_url: nil
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")
    assert has_element?(view, "#meta-branch", "axis/existing-prefix")
    assert has_element?(view, "#meta-issue", "EC-1")
    assert has_element?(view, "#meta-priority", "High")

    render_hook(view, "nonexistent_event", %{})

    dummy_socket = %Socket{assigns: %{task: nil}}
    assert {:noreply, _socket} = RailWeb.TaskDetailLive.handle_event("switch_tab", %{"tab" => "plan"}, dummy_socket)
    assert {:noreply, _socket} = RailWeb.TaskDetailLive.handle_event("random", %{}, dummy_socket)
    assert {:noreply, _socket} = RailWeb.TaskDetailLive.handle_async(:dummy, :result, dummy_socket)
    assert :ok = RailWeb.TaskDetailLive.terminate(:normal, dummy_socket)

    Rail.Repo.delete_all(from(t in Task, where: t.id == ^task_id))
    send(view.pid, {:pipeline_changed, %{task_id: task_id}})
    assert render(view) =~ "This task has been cleaned up."

    # Minimal task without worktree, issue, or pr to test all fallback branches
    %Task{id: minimal_id} =
      create_test_task(%{
        project_id: project_id,
        title: "Minimal Task",
        worktree_name: nil,
        pr_number: nil,
        pr_url: nil
      })

    assert {:ok, view_min, _html} = live(authed_conn, ~p"/tasks/#{minimal_id}")
    refute has_element?(view_min, "#meta-branch")
    refute has_element?(view_min, "#meta-issue")
    refute has_element?(view_min, "#meta-pr")

    {:ok, min_task} = Rail.Pipeline.get_task(scope, minimal_id)
    task_no_repo = %{min_task | pr_number: 123, project: %Project{github_repo: nil}}
    send(view_min.pid, {:task_updated, task_no_repo})
    assert has_element?(view_min, "#meta-pr[href='#']")
  end

  test "clicking chat and diff actions navigates to respective tabs", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    _scope = Scope.for_user(user)
    %Project{id: project_id} = create_test_project()

    %Task{id: task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :awaiting_approval,
        worktree_path: "/tmp/worktree"
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")

    # Click chat
    view |> element("#action-chat") |> render_click()
    assert_patched(view, ~p"/tasks/#{task_id}?tab=conversation")

    # Click diff
    view |> element("#action-view-diff") |> render_click()
    assert_patched(view, ~p"/tasks/#{task_id}?tab=diff")
  end

  test "confirm merge modal flow (open, cancel, submit with and without ignore_conflicts)", %{conn: conn} do
    Req.Test.set_req_test_to_shared(Rail.GitHub)
    on_exit(fn -> Req.Test.set_req_test_to_private(Rail.GitHub) end)

    Req.Test.stub(Rail.GitHub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"token" => "test_token"}))
    end)

    {authed_conn, user} = log_in_test_user(conn)
    _scope = Scope.for_user(user)
    %Project{id: project_id} = create_test_project()

    %Task{id: task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        pr_number: 202,
        pr_is_draft: false,
        mergeability: :mergeable
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")

    # Click Merge pull request button
    view |> element("#action-merge") |> render_click()
    assert has_element?(view, "#confirm-merge-modal")
    refute render(view) =~ "GitHub last reported conflicts"

    # Click Cancel
    view |> element("#cancel-merge-button") |> render_click()
    refute has_element?(view, "#confirm-merge-modal")

    # Re-open and submit
    view |> element("#action-merge") |> render_click()
    assert has_element?(view, "#confirm-merge-modal")
    view |> element("#confirm-merge-button") |> render_click()
    refute has_element?(view, "#confirm-merge-modal")

    # Conflicted task offers Merge anyway with ignore_conflicts
    %Task{id: conf_task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        pr_number: 203,
        pr_is_draft: false,
        mergeability: :conflicting
      })

    assert {:ok, conf_view, _html} = live(authed_conn, ~p"/tasks/#{conf_task_id}")
    conf_view |> element("#action-merge-anyway") |> render_click()
    assert has_element?(conf_view, "#confirm-merge-modal")
    assert render(conf_view) =~ "GitHub last reported conflicts"
    conf_view |> element("#confirm-merge-button") |> render_click()
    refute has_element?(conf_view, "#confirm-merge-modal")
  end

  test "confirm rebase modal flow (open, cancel, submit)", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    _scope = Scope.for_user(user)
    %Project{id: project_id} = create_test_project()

    %Task{id: task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        pr_number: 303,
        mergeability: :conflicting
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")

    # Click Rebase
    view |> element("#action-rebase") |> render_click()
    assert has_element?(view, "#confirm-rebase-modal")

    # Click Cancel
    view |> element("#cancel-rebase-button") |> render_click()
    refute has_element?(view, "#confirm-rebase-modal")

    # Re-open and submit
    view |> element("#action-rebase") |> render_click()
    view |> element("#confirm-rebase-button") |> render_click()
    refute has_element?(view, "#confirm-rebase-modal")
  end

  test "confirm cleanup modal flow and rejection when busy", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    _scope = Scope.for_user(user)
    %Project{id: project_id} = create_test_project()

    %Task{id: task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :awaiting_approval
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")

    # Open cleanup modal
    view |> element("#action-cleanup") |> render_click()
    assert has_element?(view, "#confirm-cleanup-modal")

    # Cancel cleanup modal
    view |> element("#cancel-cleanup-button") |> render_click()
    refute has_element?(view, "#confirm-cleanup-modal")

    # Re-open cleanup modal and submit
    view |> element("#action-cleanup") |> render_click()
    view |> element("#confirm-cleanup-button") |> render_click()
    refute has_element?(view, "#confirm-cleanup-modal")

    # Test busy task cannot open cleanup modal
    %Task{id: busy_task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :running
      })

    assert {:ok, busy_view, _html} = live(authed_conn, ~p"/tasks/#{busy_task_id}")
    assert has_element?(busy_view, "#action-cleanup[disabled]")
    render_hook(busy_view, "action_click", %{"action" => "cleanup"})
    refute has_element?(busy_view, "#confirm-cleanup-modal")
  end

  test "prompt send back modal flow (empty ignored, valid submits)", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    _scope = Scope.for_user(user)
    %Project{id: project_id} = create_test_project()

    %Task{id: task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :product,
        stage_state: :awaiting_approval
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")

    # Open modal
    view |> element("#action-send-back") |> render_click()
    assert has_element?(view, "#prompt-send-back-modal")

    # Submit empty comment -> modal remains open!
    view |> form("#prompt-send-back-form", %{comment: "   "}) |> render_submit()
    assert has_element?(view, "#prompt-send-back-modal")

    # Cancel
    view |> element("#cancel-send-back-button") |> render_click()
    refute has_element?(view, "#prompt-send-back-modal")

    # Re-open and submit valid comment
    view |> element("#action-send-back") |> render_click()
    view |> form("#prompt-send-back-form", %{comment: "Please revise the requirements"}) |> render_submit()
    refute has_element?(view, "#prompt-send-back-modal")
  end

  test "prompt send back to engineer modal flow (empty comment allowed)", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    _scope = Scope.for_user(user)
    %Project{id: project_id} = create_test_project()

    %Task{id: task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        pr_number: 404
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")

    # Open modal
    view |> element("#action-send-back-to-engineer") |> render_click()
    assert has_element?(view, "#prompt-send-back-engineer-modal")

    # Cancel modal
    view |> element("#cancel-send-back-engineer-button") |> render_click()
    refute has_element?(view, "#prompt-send-back-engineer-modal")

    # Re-open and submit empty comment (allowed)
    view |> element("#action-send-back-to-engineer") |> render_click()
    view |> form("#prompt-send-back-engineer-form", %{comment: ""}) |> render_submit()
    refute has_element?(view, "#prompt-send-back-engineer-modal")

    # Test submitting with non-empty comment on a second task
    %Task{id: task_id_2} =
      create_test_task(%{
        project_id: project_id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        pr_number: 405
      })

    assert {:ok, view_2, _html} = live(authed_conn, ~p"/tasks/#{task_id_2}")
    view_2 |> element("#action-send-back-to-engineer") |> render_click()
    view_2 |> form("#prompt-send-back-engineer-form", %{comment: "Tests failed in CI"}) |> render_submit()
    refute has_element?(view_2, "#prompt-send-back-engineer-modal")
  end

  test "prompt decline demo modal flow (empty reason defaults to 'Declined by human')", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    _scope = Scope.for_user(user)
    %Project{id: project_id} = create_test_project()

    %Task{id: task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :demo,
        stage_state: :failed
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")

    # Open modal
    view |> element("#action-decline-demo") |> render_click()
    assert has_element?(view, "#prompt-decline-demo-modal")

    # Cancel modal
    view |> element("#cancel-decline-demo-button") |> render_click()
    refute has_element?(view, "#prompt-decline-demo-modal")

    # Re-open and submit empty reason
    view |> element("#action-decline-demo") |> render_click()
    view |> form("#prompt-decline-demo-form", %{reason: "  "}) |> render_submit()
    refute has_element?(view, "#prompt-decline-demo-modal")

    # Test submitting non-empty reason on a second demo-failed task
    %Task{id: task_id_2} =
      create_test_task(%{
        project_id: project_id,
        stage: :demo,
        stage_state: :failed
      })

    assert {:ok, view_2, _html} = live(authed_conn, ~p"/tasks/#{task_id_2}")
    view_2 |> element("#action-decline-demo") |> render_click()
    view_2 |> form("#prompt-decline-demo-form", %{reason: "Backend-only change"}) |> render_submit()
    refute has_element?(view_2, "#prompt-decline-demo-modal")
  end

  test "direct action buttons dispatch corresponding pipeline actions", %{conn: conn} do
    Req.Test.set_req_test_to_shared(Rail.GitHub)
    on_exit(fn -> Req.Test.set_req_test_to_private(Rail.GitHub) end)

    Req.Test.stub(Rail.GitHub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"token" => "test_token"}))
    end)

    {authed_conn, user} = log_in_test_user(conn)
    _scope = Scope.for_user(user)
    %Project{id: project_id} = create_test_project()

    # 1. Approve & Approve skip design at product stage
    %Task{id: prod_task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :product,
        stage_state: :awaiting_approval
      })

    assert {:ok, prod_view, _html} = live(authed_conn, ~p"/tasks/#{prod_task_id}")
    assert has_element?(prod_view, "#action-approve", "Approve")
    assert has_element?(prod_view, "#action-approve-skip-design", "Approve, skip design")
    prod_view |> element("#action-approve") |> render_click()

    %Task{id: prod_skip_task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :product,
        stage_state: :awaiting_approval
      })

    assert {:ok, prod_skip_view, _html} = live(authed_conn, ~p"/tasks/#{prod_skip_task_id}")
    prod_skip_view |> element("#action-approve-skip-design") |> render_click()

    # 2. Skip to ready to merge at qa stage
    %Task{id: qa_task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :qa,
        stage_state: :awaiting_approval
      })

    assert {:ok, qa_view, _html} = live(authed_conn, ~p"/tasks/#{qa_task_id}")
    assert has_element?(qa_view, "#action-skip", "Skip")
    qa_view |> element("#action-skip") |> render_click()

    # 3. Retry on failed state
    %Task{id: retry_task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :failed
      })

    assert {:ok, retry_view, _html} = live(authed_conn, ~p"/tasks/#{retry_task_id}")
    assert has_element?(retry_view, "#action-retry", "Retry")
    retry_view |> element("#action-retry") |> render_click()

    # 4. Cancel on running task
    %Task{id: running_task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :running
      })

    assert {:ok, running_view, _html} = live(authed_conn, ~p"/tasks/#{running_task_id}")
    assert has_element?(running_view, "#action-cancel", "Cancel")
    running_view |> element("#action-cancel") |> render_click()

    # 5. Dispatch now on queued task
    %Task{id: queued_task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :queued,
        retry_after: DateTime.utc_now()
      })

    assert {:ok, queued_view, _html} = live(authed_conn, ~p"/tasks/#{queued_task_id}")
    assert has_element?(queued_view, "#action-dispatch", "Retry now")
    queued_view |> element("#action-dispatch") |> render_click()

    # 6. Unblock on blocked task without pending question
    %Task{id: blocked_task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :blocked,
        question_id: nil
      })

    assert {:ok, blocked_view, _html} = live(authed_conn, ~p"/tasks/#{blocked_task_id}")
    assert has_element?(blocked_view, "#action-unblock", "Unblock")
    blocked_view |> element("#action-unblock") |> render_click()

    # 7. Mark ready on draft PR
    %Task{id: draft_task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        pr_number: 505,
        pr_is_draft: true
      })

    assert {:ok, draft_view, _html} = live(authed_conn, ~p"/tasks/#{draft_task_id}")
    assert has_element?(draft_view, "#action-mark-ready", "Mark ready for review")
    draft_view |> element("#action-mark-ready") |> render_click()

    # 8. Rerecord demo on demo stage
    %Task{id: demo_task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :demo,
        stage_state: :failed
      })

    assert {:ok, demo_view, _html} = live(authed_conn, ~p"/tasks/#{demo_task_id}")
    assert has_element?(demo_view, "#action-rerecord-demo", "Re-record demo")
    demo_view |> element("#action-rerecord-demo") |> render_click()

    # 9. Design direction pick and recheck
    %Task{id: design_task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :design,
        stage_state: :awaiting_approval
      })

    create_test_design(%{
      task_id: design_task_id,
      directions: [
        %{key: "dir-a", title: "Direction Alpha", notes: "Notes A", still_url: "https://example.com/a.png"},
        %{key: "dir-b", title: "Direction Beta", notes: "Notes B", still_url: "https://example.com/b.png"}
      ]
    })

    assert {:ok, design_view, _html} = live(authed_conn, ~p"/tasks/#{design_task_id}")
    assert has_element?(design_view, "#action-pick-design-dir-a", "Use Direction Alpha")
    design_view |> element("#action-pick-design-dir-a") |> render_click()

    # Design recheck
    %Task{id: design_failed_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :design,
        stage_state: :failed
      })

    assert {:ok, design_failed_view, _html} = live(authed_conn, ~p"/tasks/#{design_failed_id}")
    assert has_element?(design_failed_view, "#action-recheck-design", "Design is done")
    design_failed_view |> element("#action-recheck-design") |> render_click()
  end

  test "single-flight action locking, spinner, error clearing, and PubSub broadcasts", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    _scope = Scope.for_user(user)
    %Project{id: project_id} = create_test_project()

    %Task{id: task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        pr_number: 606,
        pr_is_draft: false,
        error: "Previous error message"
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")
    assert has_element?(view, "#task-error-card", "Previous error message")

    # Broadcast task_action_started -> clears error and sets spinner
    send(view.pid, {:task_action_started, task_id, :merge})
    _html = render(view)
    refute has_element?(view, "#task-error-card")
    assert has_element?(view, "#action-merge[disabled]")
    assert has_element?(view, "#action-merge [data-qa='action-spinner']")

    # Broadcast task_action_finished -> unlocks buttons and re-enables
    send(view.pid, {:task_action_finished, task_id, :merge})
    _html = render(view)
    refute has_element?(view, "#action-merge[disabled]")
    refute has_element?(view, "#action-merge [data-qa='action-spinner']")

    # Broadcast task_action_started for different task_id is ignored
    send(view.pid, {:task_action_started, "tsk_other_999", :merge})
    _html = render(view)
    refute has_element?(view, "#action-merge[disabled]")

    # Broadcast task_action_finished for different task_id is ignored
    send(view.pid, {:task_action_finished, "tsk_other_999", :merge})
    _html = render(view)
    refute has_element?(view, "#action-merge[disabled]")
  end

  test "exercises TaskDetailLive action callbacks and modal error paths", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)
    %Project{id: project_id} = create_test_project()

    %Task{id: task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :product,
        stage_state: :awaiting_approval
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")

    # Form change event does nothing
    render_hook(view, "modal_form_change", %{})

    # Unknown action click / submit does nothing
    render_hook(view, "action_click", %{"action" => "unknown_action"})
    render_hook(view, "submit_modal", %{"action" => "unknown_modal"})

    # Direct callback testing for handle_async with crash and timeout
    dummy_task = %Task{id: task_id, project_id: project_id, stage: :product}

    dummy_socket = %Socket{
      assigns: %{
        __changed__: %{},
        task: dummy_task,
        task_id: task_id,
        current_scope: scope,
        running_action: :merge,
        active_modal: nil
      }
    }

    assert {:noreply, %{assigns: %{running_action: nil}}} =
             RailWeb.TaskDetailLive.handle_async({:task_action, :merge}, {:ok, :done}, dummy_socket)

    assert {:noreply, %{assigns: %{running_action: nil}}} =
             RailWeb.TaskDetailLive.handle_async({:task_action, :merge}, {:exit, :timeout}, dummy_socket)

    # Cleanup modal submit when busy directly returns without running
    busy_socket = %Socket{
      assigns: %{
        __changed__: %{},
        task: %{dummy_task | stage_state: :running},
        task_id: task_id,
        current_scope: scope,
        running_action: nil,
        active_modal: %{type: :confirm_cleanup}
      }
    }

    assert {:noreply, %{assigns: %{active_modal: nil}}} =
             RailWeb.TaskDetailLive.handle_event("submit_modal", %{"action" => "cleanup"}, busy_socket)
  end

  test "Overview tab renders AnswerField when blocked with pending question, handles option click, answer, and dismiss",
       %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)
    %Project{id: project_id} = create_test_project()

    task =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :blocked
      })

    question =
      create_test_question(%{
        task_id: task.id,
        prompt: "Which database adapter should be used?",
        options: ["PostgreSQL", "SQLite"],
        context_summary: "Found multiple adapters in repo",
        status: :pending
      })

    _updated =
      task
      |> Ecto.Changeset.change(%{question_id: question.id})
      |> Rail.Repo.update!()

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")

    # 1. Verify AnswerField card renders
    assert has_element?(view, "#answer-field-card")
    assert has_element?(view, "#question-prompt", "Which database adapter should be used?")
    assert has_element?(view, "#question-context-summary", "Found multiple adapters in repo")
    assert has_element?(view, "#question-option-0", "PostgreSQL")
    assert has_element?(view, "#question-option-1", "SQLite")

    # 2. Click option chip
    render_hook(view, "select_option", %{"option" => "PostgreSQL"})
    assert has_element?(view, "#answer-textarea", "PostgreSQL")

    # 3. Textarea change
    render_hook(view, "answer_form_change", %{"answer" => "PostgreSQL 16"})
    assert has_element?(view, "#answer-textarea", "PostgreSQL 16")

    # 4. Empty submit no-ops
    render_hook(view, "answer_question", %{"answer" => "   "})
    assert has_element?(view, "#answer-field-card")

    # 5. Non-empty submit with explicit question_id answers and unblocks task
    render_hook(view, "answer_question", %{"question_id" => question.id, "answer" => "PostgreSQL 16"})
    refute has_element?(view, "#answer-field-card")

    # 6. Test answer without explicit question_id (hits fallback to pending_question.id)
    task_answer_fb =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :blocked
      })

    q_fallback =
      create_test_question(%{
        task_id: task_answer_fb.id,
        prompt: "Which port?",
        options: ["5432", "5433"],
        status: :pending
      })

    _updated_fb =
      task_answer_fb
      |> Ecto.Changeset.change(%{question_id: q_fallback.id})
      |> Rail.Repo.update!()

    assert {:ok, view_fb, _html} = live(authed_conn, ~p"/tasks/#{task_answer_fb.id}")
    assert has_element?(view_fb, "#answer-field-card")
    render_hook(view_fb, "answer_question", %{"answer" => "5432"})
    refute has_element?(view_fb, "#answer-field-card")

    # 7. Test dismiss with explicit question_id param
    task_dismiss_exp =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :blocked
      })

    q2 =
      create_test_question(%{
        task_id: task_dismiss_exp.id,
        prompt: "Should we run seeds?",
        options: ["Yes", "No"],
        status: :pending
      })

    _updated_2 =
      task_dismiss_exp
      |> Ecto.Changeset.change(%{question_id: q2.id})
      |> Rail.Repo.update!()

    assert {:ok, view2, _html} = live(authed_conn, ~p"/tasks/#{task_dismiss_exp.id}")
    assert has_element?(view2, "#answer-field-card")
    render_hook(view2, "dismiss_question", %{"question_id" => q2.id})
    refute has_element?(view2, "#answer-field-card")

    # 8. Test dismiss on a blocked task without explicit question_id param (uses fallback)
    task_dismiss_fb =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :blocked
      })

    q3 =
      create_test_question(%{
        task_id: task_dismiss_fb.id,
        prompt: "Run migrations?",
        options: ["Yes", "No"],
        status: :pending
      })

    _updated_3 =
      task_dismiss_fb
      |> Ecto.Changeset.change(%{question_id: q3.id})
      |> Rail.Repo.update!()

    assert {:ok, view3, _html} = live(authed_conn, ~p"/tasks/#{task_dismiss_fb.id}")
    assert has_element?(view3, "#answer-field-card")
    render_hook(view3, "dismiss_question", %{})
    refute has_element?(view3, "#answer-field-card")

    # 7. Blocked task with invalid question_id gracefully sets pending_question to nil
    bad_task =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :blocked,
        question_id: "qst_nonexistent_99"
      })

    assert {:ok, view_bad, _html} = live(authed_conn, ~p"/tasks/#{bad_task.id}")
    refute has_element?(view_bad, "#answer-field-card")
  end

  test "Conversation tab renders empty state when task has no runs", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)
    %Project{id: project_id} = create_test_project()

    task =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :queued
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}?tab=conversation")

    assert has_element?(view, "#conversation-tab-root")
    assert has_element?(view, "#conversation-empty-state")
    assert has_element?(view, "#conversation-empty-state", "No role has run this task yet.")
  end

  test "Conversation tab handles role switching, raw log toggle, tool activity, and pubsub streaming", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)
    %Project{id: project_id} = create_test_project()

    role_arch =
      create_test_role(%{
        project_id: project_id,
        name: "Architect",
        stage: :architect,
        icon_name: "architecture"
      })

    role_eng =
      create_test_role(%{
        project_id: project_id,
        name: "Engineer",
        stage: :engineer,
        icon_name: "code"
      })

    task =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :running
      })

    now = DateTime.utc_now()

    _run_arch =
      create_test_role_run(%{
        task_id: task.id,
        role_id: role_arch.id,
        status: :finished,
        started_at: DateTime.shift(now, minute: -10),
        completed_at: DateTime.shift(now, minute: -5),
        conversation_id: "conv_arch",
        output: "[human] Architect instructions\n[run] claude\nArchitecture design complete."
      })

    run_eng =
      create_test_role_run(%{
        task_id: task.id,
        role_id: role_eng.id,
        status: :running,
        started_at: DateTime.shift(now, second: -200),
        conversation_id: "conv_eng",
        output: "[human] Engineer instructions\n[run] claude\n[tool read_file] lib/app.ex\nWriting the code now."
      })

    _run_custom =
      create_test_role_run(%{
        task_id: task.id,
        role_id: "custom_tester",
        status: :finished,
        started_at: DateTime.shift(now, second: -100),
        conversation_id: "conv_custom",
        output: "Custom agent report"
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}?tab=conversation")

    # Role chips rendered
    assert has_element?(view, "#role-chip-#{role_arch.id}")
    assert has_element?(view, "#role-chip-#{role_eng.id}")
    assert has_element?(view, "#role-chip-custom_tester")

    # Switch to architect role
    render_hook(view, "select_role", %{"role_id" => role_arch.id})
    assert has_element?(view, "#role-chip-#{role_arch.id}")
    assert has_element?(view, "[data-qa='role-bubble']", "Architecture design complete.")

    # Switch to unmapped custom role
    render_hook(view, "select_role", %{"role_id" => "custom_tester"})
    assert has_element?(view, "#role-chip-custom_tester")
    assert has_element?(view, "[data-qa='role-chip-custom_tester']", "Custom Tester")

    # Switch to engineer role
    render_hook(view, "select_role", %{"role_id" => role_eng.id})
    assert has_element?(view, "[data-qa='role-bubble']", "Writing the code now.")

    # Toggle tool activity with integer index
    assert has_element?(view, "[data-qa='activity-tile']")
    render_hook(view, "toggle_activity", %{"index" => "2"})
    assert has_element?(view, "[data-qa='activity-content']")
    assert has_element?(view, "[data-qa='activity-content']", "lib/app.ex")
    render_hook(view, "toggle_activity", %{"index" => "2"})
    refute has_element?(view, "[data-qa='activity-content']")

    # Toggle tool activity with non-numeric string index
    render_hook(view, "toggle_activity", %{"index" => "non_numeric_step"})
    render_hook(view, "toggle_activity", %{"index" => "non_numeric_step"})

    # Toggle raw log view
    render_hook(view, "toggle_raw_log", %{})
    assert has_element?(view, "#raw-log-container")
    assert has_element?(view, "[data-qa='raw-log-line']", "Writing the code now.")
    render_hook(view, "toggle_raw_log", %{})
    assert has_element?(view, "[data-qa='chat-pane']")

    # PubSub live event streaming: {:run_events, run_id, events}
    send(view.pid, {:run_events, run_eng.id, [%{line: "[tool bash] mix test"}, %{line: "Tests pass"}]})
    assert has_element?(view, "[data-qa='chat-pane']")

    # PubSub live event streaming ignored for different run_id
    send(view.pid, {:run_events, "rr_other_run", [%{line: "other line"}]})

    # PubSub {:run_finished, run_id, outcome}
    send(view.pid, {:run_finished, run_eng.id, :completed})
    assert has_element?(view, "[data-qa='chat-pane']")
  end

  test "Conversation tab chat input, delivery modal for running task, and dispatch options", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)
    %Project{id: project_id} = create_test_project()

    role_eng =
      create_test_role(%{
        project_id: project_id,
        name: "Engineer",
        stage: :engineer,
        icon_name: "code"
      })

    task =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :running
      })

    _run_eng =
      create_test_role_run(%{
        task_id: task.id,
        role_id: role_eng.id,
        status: :running,
        conversation_id: "conv_eng_chat",
        output: "[human] Hello\n[run] start\nHi there"
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}?tab=conversation")

    # Chat input change
    render_hook(view, "chat_input_change", %{"message" => "Please review tests"})
    assert has_element?(view, "#chat-input")

    # Chat input change with empty params no-ops
    render_hook(view, "chat_input_change", %{})

    # Send chat on running task triggers delivery modal
    render_hook(view, "send_chat", %{"message" => "Please review tests"})
    assert has_element?(view, "#delivery-modal-card")
    assert has_element?(view, "#delivery-modal-card", "A run is in flight")

    # Cancel delivery modal dismisses modal and keeps input
    render_hook(view, "cancel_chat_delivery", %{})
    refute has_element?(view, "#delivery-modal-card")

    # Confirm delivery with nil modal no-ops
    render_hook(view, "confirm_chat_delivery", %{"delivery" => "when_finished"})

    # Re-trigger modal and confirm with when_finished
    render_hook(view, "send_chat", %{"message" => "Please review tests"})
    assert has_element?(view, "#delivery-modal-card")
    render_hook(view, "confirm_chat_delivery", %{"delivery" => "when_finished"})
    refute has_element?(view, "#delivery-modal-card")

    # Re-trigger modal and confirm with stop_and_send
    render_hook(view, "send_chat", %{"message" => "Stop and send message"})
    assert has_element?(view, "#delivery-modal-card")
    render_hook(view, "confirm_chat_delivery", %{"delivery" => "stop_and_send"})
    refute has_element?(view, "#delivery-modal-card")

    # Stop chat turn event
    render_hook(view, "stop_chat_turn", %{})

    # Cancel pending chat event
    render_hook(view, "cancel_pending_chat", %{"role_id" => role_eng.id})
    render_hook(view, "cancel_pending_chat", %{})

    # Now make task idle
    _updated =
      task
      |> Ecto.Changeset.change(%{stage_state: :awaiting_approval})
      |> Rail.Repo.update!()

    assert {:ok, idle_view, _html} = live(authed_conn, ~p"/tasks/#{task.id}?tab=conversation")

    # Send chat on idle task with empty message no-ops
    render_hook(idle_view, "send_chat", %{"message" => "  "})

    # Send chat on idle task dispatches immediate
    render_hook(idle_view, "send_chat", %{"message" => "Hello idle agent"})

    # Test error fallback branch when send_chat_turn fails (e.g. invalid role)
    err_socket = %Socket{
      assigns: %{
        __changed__: %{},
        task: %{task | stage_state: :awaiting_approval},
        task_id: task.id,
        selected_role: %{id: "rol_missing", name: "Missing"},
        current_scope: scope,
        chat_sending: false,
        chat_input: "failing message"
      }
    }

    assert {:noreply, %{assigns: %{chat_sending: false}}} =
             RailWeb.TaskDetailLive.handle_event("send_chat", %{"message" => "failing"}, err_socket)

    # Test error fallback branch when confirm_chat_delivery fails
    err_delivery_socket = %Socket{
      assigns: %{
        __changed__: %{},
        task: task,
        task_id: task.id,
        active_delivery_modal: %{role_id: "rol_missing", text: "failing message"},
        current_scope: scope,
        chat_sending: false,
        chat_input: ""
      }
    }

    assert {:noreply, %{assigns: %{chat_sending: false}}} =
             RailWeb.TaskDetailLive.handle_event(
               "confirm_chat_delivery",
               %{"delivery" => "when_finished"},
               err_delivery_socket
             )
  end

  test "exercises TaskDetailLive chat and delivery corner cases" do
    dummy_socket = %Socket{
      assigns: %{
        __changed__: %{},
        task: nil,
        task_id: "tsk_nonexistent_0",
        selected_role: nil,
        chat_sending: true,
        chat_input: "hello",
        active_delivery_modal: nil,
        current_scope: Scope.for_system()
      }
    }

    assert {:noreply, ^dummy_socket} =
             RailWeb.TaskDetailLive.handle_event("send_chat", %{"message" => "hi"}, dummy_socket)

    assert {:noreply, ^dummy_socket} =
             RailWeb.TaskDetailLive.handle_event("confirm_chat_delivery", %{"delivery" => "stop_and_send"}, dummy_socket)

    assert {:noreply, %{assigns: %{task: nil}}} =
             RailWeb.TaskDetailLive.handle_event("stop_chat_turn", %{}, dummy_socket)

    assert {:noreply, %{assigns: %{task: nil}}} =
             RailWeb.TaskDetailLive.handle_event("cancel_pending_chat", %{}, dummy_socket)
  end

  test "diff tab displays empty state when branch has no changes and refreshes", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    repo = create_temp_git_repo()

    task =
      create_test_task(%{
        worktree_path: repo,
        owner_user_id: user.id
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}?tab=diff")

    assert has_element?(view, "#tab-diff-pane")
    assert has_element?(view, "#diff-empty-state")
    assert has_element?(view, "#diff-empty-state", "Nothing has been changed on this branch yet.")

    # Click refresh diff
    view |> element("#btn-refresh-diff") |> render_click()
    assert has_element?(view, "#diff-empty-state", "Nothing has been changed on this branch yet.")
  end

  test "diff tab loads changes, toggles viewed, and selects file in tree", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    repo = create_temp_git_repo()

    File.write!(Path.join(repo, "example.txt"), "hello world\nline two\n")

    task =
      create_test_task(%{
        worktree_path: repo,
        owner_user_id: user.id
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")

    # Switch to diff tab (lazy loading)
    view |> element("#tab-diff") |> render_click()
    assert_patched(view, ~p"/tasks/#{task.id}?tab=diff")

    assert has_element?(view, "#diff-file-tree")
    assert has_element?(view, "#diff-file-tree", "example.txt")
    assert has_element?(view, "[data-qa='diff_file_header']", "example.txt")
    assert has_element?(view, "[data-qa='diff_line_row']", "hello world")

    # Select file in tree
    view |> element("button[phx-click='select_diff_file'][phx-value-path='example.txt']") |> render_click()

    # Toggle viewed -> collapses body rows
    view
    |> element("input[phx-click='toggle_viewed'][phx-value-path='example.txt']")
    |> render_click(%{"value" => "true"})

    refute has_element?(view, "[data-qa='diff_line_row']")

    # Toggle viewed back -> expands body rows
    view
    |> element("input[phx-click='toggle_viewed'][phx-value-path='example.txt']")
    |> render_click(%{"value" => "false"})

    assert has_element?(view, "[data-qa='diff_line_row']", "hello world")
  end

  test "diff tab expands gaps when clicking expand_gap", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    repo = create_temp_git_repo()

    lines = Enum.map_join(1..15, "\n", fn i -> "orig line #{i}" end) <> "\n"
    File.write!(Path.join(repo, "gap_file.txt"), lines)
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "initial gap file"])

    git!(repo, ["checkout", "-b", "feat-gap"])
    modified = "mod line 1\n" <> Enum.map_join(2..14, "\n", fn i -> "orig line #{i}" end) <> "\nmod line 15\n"
    File.write!(Path.join(repo, "gap_file.txt"), modified)
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "modify gap file"])

    task =
      create_test_task(%{
        worktree_path: repo,
        owner_user_id: user.id
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}?tab=diff")

    assert has_element?(view, "[data-qa='diff_gap_row']")
    assert has_element?(view, "[data-qa='diff_gap_row']", "Expand 7 hidden lines")

    # Click expand gap
    view |> element("[data-qa='diff_gap_row']") |> render_click()

    refute has_element?(view, "[data-qa='diff_gap_row']")
    assert has_element?(view, "[data-qa='diff_line_row']", "orig line 5")
  end

  test "exercises diff helper functions in TaskDetailLive" do
    scope = Scope.for_system()
    task = create_test_task(%{worktree_path: nil})

    dummy_socket = %Socket{
      assigns: %{
        __changed__: %{},
        task: task,
        task_id: task.id,
        current_scope: scope,
        active_tab: :diff,
        file_diffs: [],
        loading_diff: false,
        viewed_diff_files: %{},
        expanded_gaps: %{},
        diff_rev: nil,
        selected_diff_file: nil
      }
    }

    # do_load_diff when task has no worktree results in error branch
    assert {:noreply, %{assigns: %{file_diffs: []}}} =
             RailWeb.TaskDetailLive.handle_event("refresh_diff", %{}, dummy_socket)

    # select_diff_file
    assert {:noreply, %{assigns: %{selected_diff_file: "test.ex"}}} =
             RailWeb.TaskDetailLive.handle_event("select_diff_file", %{"path" => "test.ex"}, dummy_socket)

    # toggle_viewed with toggle logic
    assert {:noreply, %{assigns: %{viewed_diff_files: %{"test.ex" => "h1"}}}} =
             RailWeb.TaskDetailLive.handle_event(
               "toggle_viewed",
               %{"path" => "test.ex", "digest" => "h1"},
               dummy_socket
             )

    # expand_gap with nil lines or missing worktree
    assert {:noreply, %{assigns: %{expanded_gaps: %{"test.ex:0" => []}}}} =
             RailWeb.TaskDetailLive.handle_event(
               "expand_gap",
               %{"path" => "test.ex", "gap_index" => "0", "start_line" => "1", "end_line" => "5"},
               dummy_socket
             )
  end

  test "renders design panel when task has design attached", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)

    task =
      create_test_task(%{
        owner_user_id: user.id,
        stage: :engineer,
        stage_state: :running
      })

    _design =
      create_test_design(%{
        task_id: task.id,
        version: 2,
        canvas_url: "https://canvas.example.com/project/42",
        directions: [
          %{
            key: "dir-a",
            title: "Direction Alpha",
            notes: "Design notes here",
            still_url: "https://uploads.linear.app/still_a.png"
          }
        ]
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#design-panel")
    assert has_element?(view, "#design-panel-title", "Design directions")
    assert has_element?(view, "#design-version-pill", "v2")
    assert has_element?(view, "#design-direction-card-dir-a")
    assert has_element?(view, "#design-direction-title-dir-a", "Direction Alpha")
    assert has_element?(view, "#design-canvas-link")
  end

  test "renders demo panel when task has demo attached", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)

    task =
      create_test_task(%{
        owner_user_id: user.id,
        stage: :engineer,
        stage_state: :running
      })

    _demo =
      create_test_demo(%{
        task_id: task.id,
        version: 1,
        outcome: "recorded",
        segments: [
          %{
            criterion_index: 1,
            criterion: "Form submits properly",
            outcome: :recorded,
            frames: [
              %{
                path: "f1.png",
                linear_asset_id: "ast_1",
                url: "https://uploads.linear.app/demo/f1.png",
                hold_ms: 1000,
                caption: "Step 1"
              }
            ]
          }
        ]
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#demo-panel")
    assert has_element?(view, "#demo-panel-title", "Recorded demo")
    assert has_element?(view, "#demo-version-pill", "v1")
    assert has_element?(view, "#demo-recorded-count-pill", "1/1 recorded")
    assert has_element?(view, "#demo-play-all-btn")
    refute has_element?(view, "#no-demo-banner")
  end

  test "renders no-demo banner when stage is ready_to_merge and no demo exists", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)

    task =
      create_test_task(%{
        owner_user_id: user.id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#no-demo-banner")
    assert has_element?(view, "#no-demo-title", "No demo recorded")

    assert has_element?(
             view,
             "#no-demo-body",
             "This task reached Ready to merge without recording a demo (gates were skipped)."
           )

    refute has_element?(view, "#demo-panel")
  end

  test "opens demo player modal, navigates controls, and closes modal", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)

    task =
      create_test_task(%{
        owner_user_id: user.id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: "/tmp/fake-worktree"
      })

    _demo =
      create_test_demo(%{
        task_id: task.id,
        version: 1,
        outcome: "recorded",
        segments: [
          %{
            criterion_index: 1,
            criterion: "First criterion",
            outcome: :recorded,
            frames: [
              %{
                path: "f1.png",
                linear_asset_id: "ast_1",
                url: "https://uploads.linear.app/demo/f1.png",
                hold_ms: 1000,
                caption: "Caption 1"
              },
              %{
                path: "f2.png",
                linear_asset_id: "ast_2",
                url: "https://uploads.linear.app/demo/f2.png",
                hold_ms: 1000,
                caption: "Caption 2"
              }
            ]
          },
          %{
            criterion_index: 2,
            criterion: "Second criterion",
            outcome: :recorded,
            frames: [
              %{
                path: "f3.png",
                linear_asset_id: "ast_3",
                url: "https://uploads.linear.app/demo/f3.png",
                hold_ms: 1500,
                caption: "Caption 3"
              }
            ]
          }
        ]
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")

    refute has_element?(view, "#demo-player-modal")

    # Click Play all to open modal
    assert view |> element("#demo-play-all-btn") |> render_click()

    assert has_element?(view, "#demo-player-modal")
    assert has_element?(view, "#demo-player-criterion-text", "First criterion")
    assert has_element?(view, "#demo-player-caption-overlay", "Caption 1")

    # Click Next frame
    assert view |> element("#demo-player-next-frame") |> render_click()
    assert has_element?(view, "#demo-player-caption-overlay", "Caption 2")

    # Click Previous frame
    assert view |> element("#demo-player-prev-frame") |> render_click()
    assert has_element?(view, "#demo-player-caption-overlay", "Caption 1")

    # Click Next segment
    assert view |> element("#demo-player-next-segment") |> render_click()
    assert has_element?(view, "#demo-player-criterion-text", "Second criterion")
    assert has_element?(view, "#demo-player-caption-overlay", "Caption 3")

    # Click Previous segment
    assert view |> element("#demo-player-prev-segment") |> render_click()
    assert has_element?(view, "#demo-player-criterion-text", "First criterion")

    # Toggle play/pause
    assert view |> element("#demo-player-play-toggle") |> render_click()

    # Toggle loop
    assert view |> element("#demo-player-loop-toggle") |> render_click()

    # Seek
    assert view
           |> element("#demo-player-seek-form")
           |> render_change(%{"ms" => "500"})

    # Close modal
    assert view |> element("#demo-player-close-btn") |> render_click()
    refute has_element?(view, "#demo-player-modal")
  end

  test "exercises demo player and rerecord_demo unit events on TaskDetailLive" do
    scope = Scope.for_system()
    task = create_test_task(%{worktree_path: nil})

    demo = %Rail.Artifacts.Schemas.Demo{
      id: "demo_unit_test",
      task_id: task.id,
      version: 1,
      outcome: "recorded",
      segments: [
        %{
          criterion_index: 1,
          criterion: "Segment 1",
          outcome: :recorded,
          frames: [
            %{path: "f1.png", hold_ms: 1000, caption: "Frame 1"}
          ]
        }
      ]
    }

    dummy_socket = %Socket{
      assigns: %{
        __changed__: %{},
        task: task,
        task_id: task.id,
        current_scope: scope,
        demo: demo,
        demo_player: nil
      }
    }

    # play_demo with nil demo
    nil_demo_socket = %{dummy_socket | assigns: %{dummy_socket.assigns | demo: nil}}

    assert {:noreply, ^nil_demo_socket} =
             RailWeb.TaskDetailLive.handle_event("play_demo", %{}, nil_demo_socket)

    # play_demo with valid demo (string segment index)
    assert {:noreply, socket_with_player} =
             RailWeb.TaskDetailLive.handle_event(
               "play_demo",
               %{"segment" => "0"},
               dummy_socket
             )

    assert %RailWeb.Components.DemoPlayerState{is_playing: true} =
             socket_with_player.assigns.demo_player

    # play_demo with integer segment index
    assert {:noreply, _socket} =
             RailWeb.TaskDetailLive.handle_event(
               "play_demo",
               %{"segment" => 0},
               dummy_socket
             )

    # play_demo with invalid segment index string
    assert {:noreply, _socket} =
             RailWeb.TaskDetailLive.handle_event(
               "play_demo",
               %{"segment" => "invalid"},
               dummy_socket
             )

    # play_demo with missing segment parameter
    assert {:noreply, _socket} =
             RailWeb.TaskDetailLive.handle_event(
               "play_demo",
               %{},
               dummy_socket
             )

    # player events with nil player
    assert {:noreply, ^dummy_socket} =
             RailWeb.TaskDetailLive.handle_event("player_toggle_play", %{}, dummy_socket)

    assert {:noreply, ^dummy_socket} =
             RailWeb.TaskDetailLive.handle_event("player_next_frame", %{}, dummy_socket)

    assert {:noreply, ^dummy_socket} =
             RailWeb.TaskDetailLive.handle_event("player_prev_frame", %{}, dummy_socket)

    assert {:noreply, ^dummy_socket} =
             RailWeb.TaskDetailLive.handle_event("player_next_segment", %{}, dummy_socket)

    assert {:noreply, ^dummy_socket} =
             RailWeb.TaskDetailLive.handle_event("player_prev_segment", %{}, dummy_socket)

    assert {:noreply, ^dummy_socket} =
             RailWeb.TaskDetailLive.handle_event("player_seek", %{"ms" => 100}, dummy_socket)

    assert {:noreply, ^dummy_socket} =
             RailWeb.TaskDetailLive.handle_event("player_toggle_loop", %{}, dummy_socket)

    # player_seek with integer ms
    assert {:noreply, %{assigns: %{demo_player: %{elapsed_ms: 500}}}} =
             RailWeb.TaskDetailLive.handle_event(
               "player_seek",
               %{"ms" => 500},
               socket_with_player
             )

    # player_seek with invalid string ms
    assert {:noreply, %{assigns: %{demo_player: %{elapsed_ms: 0}}}} =
             RailWeb.TaskDetailLive.handle_event(
               "player_seek",
               %{"ms" => "bad"},
               socket_with_player
             )

    # player_seek with non-number ms
    assert {:noreply, %{assigns: %{demo_player: %{elapsed_ms: 0}}}} =
             RailWeb.TaskDetailLive.handle_event(
               "player_seek",
               %{"ms" => nil},
               socket_with_player
             )

    # handle_info(:demo_player_tick) when playing
    assert {:noreply, %{assigns: %{demo_player: %{elapsed_ms: 50}}}} =
             RailWeb.TaskDetailLive.handle_info(:demo_player_tick, socket_with_player)

    # handle_info(:demo_player_tick) when demo_player is nil
    assert {:noreply, ^dummy_socket} =
             RailWeb.TaskDetailLive.handle_info(:demo_player_tick, dummy_socket)

    # handle_info(:demo_player_tick) when paused
    paused_player = %{socket_with_player.assigns.demo_player | is_playing: false}
    paused_socket = %{socket_with_player | assigns: %{socket_with_player.assigns | demo_player: paused_player}}

    assert {:noreply, ^paused_socket} =
             RailWeb.TaskDetailLive.handle_info(:demo_player_tick, paused_socket)

    # player_toggle_play when paused starts playing
    assert {:noreply, %{assigns: %{demo_player: %{is_playing: true}}}} =
             RailWeb.TaskDetailLive.handle_event("player_toggle_play", %{}, paused_socket)

    # rerecord_demo event delegates to handle_action_click
    assert {:noreply, _socket} =
             RailWeb.TaskDetailLive.handle_event("rerecord_demo", %{}, dummy_socket)
  end
end
