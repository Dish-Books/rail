defmodule RailWeb.TaskDetailLiveTest do
  use RailWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

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
    assert has_element?(view, "#diff-stub-content")
    assert has_element?(view, "#diff-stub-content", "/tmp/worktree/tab-task")

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

    dummy_socket = %Phoenix.LiveView.Socket{assigns: %{task: nil}}
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
end
