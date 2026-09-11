defmodule RailWeb.TaskDetailLiveTest do
  use RailWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import RailTest.PipelineHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias Phoenix.LiveView.Socket
  alias Rail.Artifacts
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Scope
  alias Rail.Users
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Task Detail Workspace",
        external_id: "lin_ws_task_detail",
        token: "lin_api_token_task_detail",
        webhook_secret: "whsec_task_detail"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Task Detail Project 13801",
        github_repo: "org/task-detail-13801",
        github_installation_id: 13_801,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_task_detail_13801",
        linear_team_key: "P13801",
        default_branch: "main",
        clone_path: "/tmp/repos/task-detail-13801",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    %{backend: backend, workspace: workspace, project: project}
  end

  test "redirects unauthenticated user to /auth/github", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/github"}}} = live(conn, ~p"/tasks/tsk_dummy")
  end

  test "renders task cleaned-up state when task is not found", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_1",
        login: "task_detail_user_1",
        email: "task_detail_user_1@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/nonexistent-123")

    assert has_element?(view, "#task-detail-view")
    assert has_element?(view, "#task-detail-title", "Task")
    assert has_element?(view, "#task-cleaned-up")
    assert has_element?(view, "#task-cleaned-up", "This task has been cleaned up.")
  end

  test "renders task details with header, project badge, tabs, stepper, metadata wrap, and ticket", %{
    conn: conn
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_2",
        login: "task_detail_user_2",
        email: "task_detail_user_2@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: _project_id} = project} =
             Projects.create_project(scope, %{
               name: "Detail Project",
               github_repo: "example/detail-project",
               github_installation_id: 603,
               linear_team_id: "t_det",
               linear_team_key: "DET",
               default_branch: "main",
               clone_path: "/tmp/detail-project",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_detail_13823",
      "identifier" => "DET-42",
      "title" => "Task Detail Issue 13823"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Task Detail Issue 13823")

    {:ok, issue} =
      Issues.update_issue(system_scope(), issue, %{
        branch_name: "feature-branch"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13826",
      "identifier" => "TSK-13826",
      "title" => "Implement Login Flow"
    })

    {:ok, issue_13826} = Issues.capture_issue(system_scope(), project, "Implement Login Flow")

    {:ok, task} = Pipeline.create_task(issue_13826, :product)

    Repo.update_all(from(i in Issue, where: i.id == ^issue.id),
      set: [title: "Implement Login Flow", description: "Must handle OAuth callbacks cleanly"]
    )

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        issue_id: issue.id,
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
    assert has_element?(view, "#meta-branch", "rail/login-flow")
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

  test "switches tabs and displays tab panes", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_3",
        login: "task_detail_user_3",
        email: "task_detail_user_3@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: _project_id}} =
             Projects.create_project(scope, %{
               name: "Tab Switching Project",
               github_repo: "example/tab-project",
               github_installation_id: 605,
               linear_team_id: "t_tab",
               linear_team_key: "TAB",
               default_branch: "main",
               clone_path: "/tmp/tab-project",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13827",
      "identifier" => "TSK-13827",
      "title" => "Tab Switching Task"
    })

    {:ok, issue_13827} = Issues.capture_issue(system_scope(), project, "Tab Switching Task")

    {:ok, task} = Pipeline.create_task(issue_13827, :product)

    Repo.update_all(from(i in Issue, where: i.id == ^Repo.get!(Task, task.id).issue_id),
      set: [description: "Testing tabs"]
    )

    tab_worktree = create_temp_git_repo()

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :running,
        worktree_path: tab_worktree
      })

    %Plan{}
    |> Plan.changeset(
      %{content: "## Architectural Plan\n1. Step one\n2. Step two", captured_at: DateTime.utc_now()},
      task.id
    )
    |> Repo.insert!()

    {:ok, _plan} = Pipeline.get_plan(system_scope(), task)

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
    assert has_element?(view, "#tab-diff-pane", tab_worktree)
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

  test "renders plan empty state when no plan exists", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_4",
        login: "task_detail_user_4",
        email: "task_detail_user_4@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: _project_id}} =
             Projects.create_project(scope, %{
               name: "No Plan Project",
               github_repo: "example/no-plan",
               github_installation_id: 606,
               linear_team_id: "t_np",
               linear_team_key: "NP",
               default_branch: "main",
               clone_path: "/tmp/no-plan",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13828",
      "identifier" => "TSK-13828",
      "title" => "No Plan Task"
    })

    {:ok, issue_13828} = Issues.capture_issue(system_scope(), project, "No Plan Task")

    {:ok, task} = Pipeline.create_task(issue_13828, :product)

    Repo.update_all(from(i in Issue, where: i.id == ^Repo.get!(Task, task.id).issue_id),
      set: [description: "Task without plan"]
    )

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}?tab=plan")
    assert has_element?(view, "#plan-empty-state")
    assert has_element?(view, "#plan-empty-state", "No plan has been written yet.")
  end

  test "renders diff empty state when worktree_path is nil", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_5",
        login: "task_detail_user_5",
        email: "task_detail_user_5@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: _project_id}} =
             Projects.create_project(scope, %{
               name: "No Worktree Project",
               github_repo: "example/no-wt",
               github_installation_id: 607,
               linear_team_id: "t_nw",
               linear_team_key: "NW",
               default_branch: "main",
               clone_path: "/tmp/no-wt",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13829",
      "identifier" => "TSK-13829",
      "title" => "No Worktree Task"
    })

    {:ok, issue_13829} = Issues.capture_issue(system_scope(), project, "No Worktree Task")

    {:ok, task} = Pipeline.create_task(issue_13829, :product)

    Repo.update_all(from(i in Issue, where: i.id == ^Repo.get!(Task, task.id).issue_id),
      set: [description: "Task without worktree"]
    )

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued,
        worktree_path: "/tmp/rail-removed-worktree"
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}?tab=diff")
    assert has_element?(view, "#diff-empty-state")
    assert has_element?(view, "#diff-empty-state", "This task has no worktree.")
  end

  test "renders conflict banner when task has merge conflicts and not rebasing", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_6",
        login: "task_detail_user_6",
        email: "task_detail_user_6@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: _project_id}} =
             Projects.create_project(scope, %{
               name: "Conflict Project",
               github_repo: "example/conflict",
               github_installation_id: 608,
               linear_team_id: "t_cf",
               linear_team_key: "CF",
               default_branch: "main",
               clone_path: "/tmp/conflict",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13830",
      "identifier" => "TSK-13830",
      "title" => "Conflicted Task"
    })

    {:ok, issue_13830} = Issues.capture_issue(system_scope(), project, "Conflicted Task")

    {:ok, conflicted_task} = Pipeline.create_task(issue_13830, :product)

    Repo.update_all(from(i in Issue, where: i.id == ^Repo.get!(Task, conflicted_task.id).issue_id),
      set: [description: "Merge conflict present"]
    )

    {:ok, conflicted_task} =
      Pipeline.update_task(system_scope(), conflicted_task.id, %{
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
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13831",
      "identifier" => "TSK-13831",
      "title" => "Rebasing Task"
    })

    {:ok, issue_13831} = Issues.capture_issue(system_scope(), project, "Rebasing Task")

    {:ok, rebasing_task} = Pipeline.create_task(issue_13831, :product)

    Repo.update_all(from(i in Issue, where: i.id == ^Repo.get!(Task, rebasing_task.id).issue_id),
      set: [description: "Actively rebasing"]
    )

    {:ok, rebasing_task} =
      Pipeline.update_task(system_scope(), rebasing_task.id, %{
        stage: :engineer,
        stage_state: :running,
        mergeability: :conflicting,
        is_rebasing: true,
        pr_number: 43
      })

    assert {:ok, rebasing_view, _html} = live(authed_conn, ~p"/tasks/#{rebasing_task.id}")
    refute has_element?(rebasing_view, "#conflict-banner")
  end

  test "renders error card when task has error", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_7",
        login: "task_detail_user_7",
        email: "task_detail_user_7@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: _project_id}} =
             Projects.create_project(scope, %{
               name: "Error Project",
               github_repo: "example/error",
               github_installation_id: 609,
               linear_team_id: "t_err",
               linear_team_key: "ERR",
               default_branch: "main",
               clone_path: "/tmp/error",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13832",
      "identifier" => "TSK-13832",
      "title" => "Error Task"
    })

    {:ok, issue_13832} = Issues.capture_issue(system_scope(), project, "Error Task")

    {:ok, task} = Pipeline.create_task(issue_13832, :product)

    Repo.update_all(from(i in Issue, where: i.id == ^Repo.get!(Task, task.id).issue_id),
      set: [description: "Task with error"]
    )

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :failed,
        error: "Elixir compilation error in test/dummy_test.exs:10"
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#task-error-card")
    assert has_element?(view, "#task-error-card", "Elixir compilation error")
  end

  test "renders stage outcome when role run output and failure details exist", %{
    backend: backend,
    conn: conn,
    project: project
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_8",
        login: "task_detail_user_8",
        email: "task_detail_user_8@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Outcome Project",
               github_repo: "example/outcome",
               github_installation_id: 610,
               linear_team_id: "t_out",
               linear_team_key: "OUT",
               default_branch: "main",
               clone_path: "/tmp/outcome",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    {:ok, role} =
      Roles.create_role(system_scope(), project_id, %{
        backend_id: backend.id,
        name: "Engineer",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 13815.",
        stage: :engineer
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13833",
      "identifier" => "TSK-13833",
      "title" => "Outcome Task"
    })

    {:ok, issue_13833} = Issues.capture_issue(system_scope(), project, "Outcome Task")

    {:ok, task} = Pipeline.create_task(issue_13833, :product)

    Repo.update_all(from(i in Issue, where: i.id == ^Repo.get!(Task, task.id).issue_id),
      set: [description: "Task with role run"]
    )

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
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

  test "skips design stage when project/task does not use design", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_9",
        login: "task_detail_user_9",
        email: "task_detail_user_9@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: _project_id}} =
             Projects.create_project(scope, %{
               name: "No Design Project",
               github_repo: "example/no-design",
               github_installation_id: 611,
               linear_team_id: "t_nd",
               linear_team_key: "ND",
               default_branch: "main",
               clone_path: "/tmp/no-design",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13834",
      "identifier" => "TSK-13834",
      "title" => "Backend API Task"
    })

    {:ok, issue_13834} = Issues.capture_issue(system_scope(), project, "Backend API Task")

    {:ok, task} = Pipeline.create_task(issue_13834, :product)

    Repo.update_all(from(i in Issue, where: i.id == ^Repo.get!(Task, task.id).issue_id),
      set: [description: "Pure backend work"]
    )

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#stage-stepper")
    assert has_element?(view, "#stage-chip-engineer")
    refute has_element?(view, "#stage-chip-design")
  end

  test "handles PubSub updates and LiveSync messages reactively", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_10",
        login: "task_detail_user_10",
        email: "task_detail_user_10@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: _project_id}} =
             Projects.create_project(scope, %{
               name: "PubSub Project",
               github_repo: "example/pubsub",
               github_installation_id: 612,
               linear_team_id: "t_ps",
               linear_team_key: "PS",
               default_branch: "main",
               clone_path: "/tmp/pubsub",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13835",
      "identifier" => "TSK-13835",
      "title" => "Initial Title"
    })

    {:ok, issue_13835} = Issues.capture_issue(system_scope(), project, "Initial Title")

    {:ok, %Task{id: target_id}} = Pipeline.create_task(issue_13835, :product)

    {:ok, %Task{id: target_id}} =
      Pipeline.update_task(system_scope(), %Task{id: target_id}.id, %{
        stage: :product,
        stage_state: :queued
      })

    issue_id = Repo.get!(Task, target_id).issue_id

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{target_id}")
    assert has_element?(view, "#task-detail-title", "Initial Title")

    # 1. PubSub :pipeline_changed with matching task_id
    Repo.update_all(
      from(i in Issue, where: i.id == ^issue_id),
      set: [title: "Updated via Pipeline Event"]
    )

    send(view.pid, {:pipeline_changed, %{task_id: target_id}})
    assert render(view) =~ "Updated via Pipeline Event"

    # PubSub :pipeline_changed with non-matching task_id is ignored
    send(view.pid, {:pipeline_changed, %{task_id: "tsk_other"}})
    assert render(view) =~ "Updated via Pipeline Event"

    # 2. LiveSync event with atom :id
    Repo.update_all(
      from(i in Issue, where: i.id == ^issue_id),
      set: [title: "Updated via LiveSync Atom"]
    )

    send(view.pid, {:livesync, :tasks, "tasks", :update, %{id: target_id}})
    assert render(view) =~ "Updated via LiveSync Atom"

    # 3. LiveSync event with string "id"
    Repo.update_all(
      from(i in Issue, where: i.id == ^issue_id),
      set: [title: "Updated via LiveSync String"]
    )

    send(view.pid, {:livesync, :tasks, "tasks", :update, %{"id" => target_id}})
    assert render(view) =~ "Updated via LiveSync String"

    # LiveSync with non-matching or invalid record
    send(view.pid, {:livesync, :tasks, "tasks", :update, %{id: "tsk_other"}})
    send(view.pid, {:livesync, :tasks, "tasks", :update, :not_a_map})
    assert render(view) =~ "Updated via LiveSync String"

    # 4. Direct :task_updated message
    {:ok, updated_task} = Pipeline.get_task(scope, target_id)
    updated_task = %{updated_task | issue: %{updated_task.issue | title: "Directly Updated Task"}}
    send(view.pid, {:task_updated, updated_task})
    assert render(view) =~ "Directly Updated Task"

    # Direct :task_updated message with different task id is ignored
    send(view.pid, {:task_updated, %Task{id: "tsk_different"}})
    assert render(view) =~ "Directly Updated Task"

    # 5. Unknown message and async handling
    send(view.pid, :some_unknown_info)
    send(view.pid, {:unknown, "message"})
    assert render(view) =~ "Directly Updated Task"
  end

  test "handles ?project=<id> param and project switcher", %{conn: conn, project: _project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_11",
        login: "task_detail_user_11",
        email: "task_detail_user_11@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id, name: project_name}} =
             Projects.create_project(scope, %{
               name: "Project Switcher Task",
               github_repo: "example/pst",
               github_installation_id: 604,
               linear_team_id: "t_pst",
               linear_team_key: "PST",
               default_branch: "main",
               clone_path: "/tmp/pst",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/some-task?project=#{project_id}")
    assert has_element?(view, "#selected-project-name", project_name)

    # Patch without project
    view |> element("#project-switcher-button") |> render_click()
    view |> element("#project-option-all") |> render_click()

    assert_patched(view, ~p"/tasks/some-task")
    assert has_element?(view, "#selected-project-name", "All projects")
  end

  test "formats various metadata fallbacks and roles gracefully", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_12",
        login: "task_detail_user_12",
        email: "task_detail_user_12@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: _project_id}} =
             Projects.create_project(scope, %{
               name: "Fallback Project",
               github_repo: "example/fallback",
               github_installation_id: 613,
               linear_team_id: "t_fb",
               linear_team_key: "FB",
               default_branch: "main",
               clone_path: "/tmp/fallback",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    # Task with issue branch name instead of worktree name, and pr_number without full pr_url
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_detail_13824",
      "identifier" => "FB-99",
      "title" => "Task Detail Issue 13824"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Task Detail Issue 13824")

    {:ok, issue} =
      Issues.update_issue(system_scope(), issue, %{
        branch_name: "rail/issue-branch",
        priority: :urgent
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13836",
      "identifier" => "TSK-13836",
      "title" => "Metadata Fallback Task"
    })

    {:ok, issue_13836} = Issues.capture_issue(system_scope(), project, "Metadata Fallback Task")

    {:ok, task} = Pipeline.create_task(issue_13836, :product)

    Repo.update_all(from(i in Issue, where: i.id == ^issue.id),
      set: [description: "## Ticket\n\nTicket description content\n\n## Implementation Plan\n\nPlan details"]
    )

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        issue_id: issue.id,
        stage: :architect,
        stage_state: :queued,
        worktree_name: "removed-worktree",
        pr_number: 55,
        pr_url: nil,
        priority: nil
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#meta-branch", "rail/removed-worktree")
    assert has_element?(view, "#meta-issue", "FB-99")
    assert has_element?(view, "#meta-pr", "PR #55")
    assert has_element?(view, "#meta-priority", "Urgent")
    assert has_element?(view, "#ticket-section", "Ticket description content")
  end

  test "exercises LiveView callbacks and edge-case branches", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_13",
        login: "task_detail_user_13",
        email: "task_detail_user_13@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: _project_id}} =
             Projects.create_project(scope, %{
               name: "Edge Case Project",
               github_repo: "example/edge-case",
               github_installation_id: 614,
               linear_team_id: "t_ec",
               linear_team_key: "EC",
               default_branch: "main",
               clone_path: "/tmp/edge-case",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_detail_13825",
      "identifier" => "EC-1",
      "title" => "Task Detail Issue 13825"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Task Detail Issue 13825")

    {:ok, issue} =
      Issues.update_issue(system_scope(), issue, %{
        priority: :high
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13837",
      "identifier" => "TSK-13837",
      "title" => "Edge Case Task"
    })

    {:ok, issue_13837} = Issues.capture_issue(system_scope(), project, "Edge Case Task")

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_13837, :product)

    Repo.update_all(from(i in Issue, where: i.id == ^issue.id), set: [description: "Edge case description"])

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: task_id}.id, %{
        issue_id: issue.id,
        stage: :demo,
        stage_state: :running,
        worktree_name: "rail/existing-prefix",
        pr_number: 99,
        pr_url: nil
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")

    # The LiveView process issues the GitHub call, so lend it the stubs.

    Req.Test.allow(Rail.GitHub, self(), view.pid)

    Sandbox.allow(Repo, self(), view.pid)
    assert has_element?(view, "#meta-branch", "rail/existing-prefix")
    assert has_element?(view, "#meta-issue", "EC-1")
    assert has_element?(view, "#meta-priority", "High")

    render_hook(view, "nonexistent_event", %{})

    dummy_socket = %Socket{assigns: %{task: nil}}
    assert {:noreply, _socket} = RailWeb.TaskDetailLive.handle_event("switch_tab", %{"tab" => "plan"}, dummy_socket)
    assert {:noreply, _socket} = RailWeb.TaskDetailLive.handle_event("random", %{}, dummy_socket)
    assert {:noreply, _socket} = RailWeb.TaskDetailLive.handle_async(:dummy, :result, dummy_socket)
    assert :ok = RailWeb.TaskDetailLive.terminate(:normal, dummy_socket)

    Repo.delete_all(from(t in Task, where: t.id == ^task_id))
    send(view.pid, {:pipeline_changed, %{task_id: task_id}})
    assert render(view) =~ "This task has been cleaned up."

    # Minimal task without worktree, issue, or pr to test all fallback branches
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13838",
      "identifier" => "TSK-13838",
      "title" => "Minimal Task"
    })

    {:ok, issue_13838} = Issues.capture_issue(system_scope(), project, "Minimal Task")

    {:ok, %Task{id: minimal_id}} = Pipeline.create_task(issue_13838, :product)

    {:ok, %Task{id: minimal_id}} =
      Pipeline.update_task(system_scope(), %Task{id: minimal_id}.id, %{
        issue_id: nil,
        worktree_name: "removed-worktree",
        pr_number: nil,
        pr_url: nil
      })

    assert {:ok, view_min, _html} = live(authed_conn, ~p"/tasks/#{minimal_id}")
    assert has_element?(view_min, "#meta-branch", "rail/removed-worktree")
    refute has_element?(view_min, "#meta-issue")
    refute has_element?(view_min, "#meta-pr")

    {:ok, min_task} = Pipeline.get_task(scope, minimal_id)
    task_no_repo = %{min_task | pr_number: 123, project: %Project{github_repo: nil}}
    send(view_min.pid, {:task_updated, task_no_repo})
    assert has_element?(view_min, "#meta-pr[href='#']")
  end

  test "clicking chat and diff actions navigates to respective tabs", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_14",
        login: "task_detail_user_14",
        email: "task_detail_user_14@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    _scope = Scope.for_user(user)

    {:ok, %Project{id: _project_id}} =
      Projects.create_project(system_scope(), %{
        name: "Task Detail Tabs Project",
        github_repo: "org/task-detail-tabs",
        github_installation_id: 13_801,
        linear_team_id: "team_task_detail_tabs",
        linear_team_key: "TDT",
        default_branch: "main",
        clone_path: "/tmp/repos/task-detail-tabs",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13839",
      "identifier" => "TSK-13839",
      "title" => "Task 13839"
    })

    {:ok, issue_13839} = Issues.capture_issue(system_scope(), project, "Task 13839")

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_13839, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: task_id}.id, %{
        stage: :engineer,
        stage_state: :awaiting_approval,
        worktree_path: create_temp_git_repo()
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")

    # The LiveView process issues the GitHub call, so lend it the stubs.

    Req.Test.allow(Rail.GitHub, self(), view.pid)

    Sandbox.allow(Repo, self(), view.pid)

    # Click chat
    view |> element("#action-chat") |> render_click()
    assert_patched(view, ~p"/tasks/#{task_id}?tab=conversation")

    # Click diff
    view |> element("#action-view-diff") |> render_click()
    assert_patched(view, ~p"/tasks/#{task_id}?tab=diff")
  end

  test "confirm merge modal flow (open, cancel, submit with and without ignore_conflicts)", %{
    conn: conn,
    project: project
  } do
    Req.Test.stub(Rail.GitHub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"token" => "test_token"}))
    end)

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_15",
        login: "task_detail_user_15",
        email: "task_detail_user_15@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    _scope = Scope.for_user(user)

    {:ok, %Project{id: _project_id}} =
      Projects.create_project(system_scope(), %{
        name: "Task Detail Project 13802",
        github_repo: "org/task-detail-13802",
        github_installation_id: 13_802,
        linear_team_id: "team_task_detail_13802",
        linear_team_key: "P13802",
        default_branch: "main",
        clone_path: "/tmp/repos/task-detail-13802",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13840",
      "identifier" => "TSK-13840",
      "title" => "Task 13840"
    })

    {:ok, issue_13840} = Issues.capture_issue(system_scope(), project, "Task 13840")

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_13840, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: task_id}.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        pr_number: 202,
        pr_is_draft: false,
        mergeability: :mergeable
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")

    # The LiveView process issues the GitHub call, so lend it the stubs.

    Req.Test.allow(Rail.GitHub, self(), view.pid)

    Sandbox.allow(Repo, self(), view.pid)

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
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13841",
      "identifier" => "TSK-13841",
      "title" => "Task 13841"
    })

    {:ok, issue_13841} = Issues.capture_issue(system_scope(), project, "Task 13841")

    {:ok, %Task{id: conf_task_id}} = Pipeline.create_task(issue_13841, :product)

    {:ok, %Task{id: conf_task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: conf_task_id}.id, %{
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

  test "confirm rebase modal flow (open, cancel, submit)", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_16",
        login: "task_detail_user_16",
        email: "task_detail_user_16@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    _scope = Scope.for_user(user)

    {:ok, %Project{id: _project_id}} =
      Projects.create_project(system_scope(), %{
        name: "Task Detail Project 13803",
        github_repo: "org/task-detail-13803",
        github_installation_id: 13_803,
        linear_team_id: "team_task_detail_13803",
        linear_team_key: "P13803",
        default_branch: "main",
        clone_path: "/tmp/repos/task-detail-13803",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13842",
      "identifier" => "TSK-13842",
      "title" => "Task 13842"
    })

    {:ok, issue_13842} = Issues.capture_issue(system_scope(), project, "Task 13842")

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_13842, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: task_id}.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        pr_number: 303,
        mergeability: :conflicting
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")

    # The LiveView process issues the GitHub call, so lend it the stubs.

    Req.Test.allow(Rail.GitHub, self(), view.pid)

    Sandbox.allow(Repo, self(), view.pid)

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

  test "confirm cleanup modal flow and rejection when busy", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_17",
        login: "task_detail_user_17",
        email: "task_detail_user_17@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    _scope = Scope.for_user(user)

    {:ok, %Project{id: _project_id}} =
      Projects.create_project(system_scope(), %{
        name: "Task Detail Project 13804",
        github_repo: "org/task-detail-13804",
        github_installation_id: 13_804,
        linear_team_id: "team_task_detail_13804",
        linear_team_key: "P13804",
        default_branch: "main",
        clone_path: "/tmp/repos/task-detail-13804",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13843",
      "identifier" => "TSK-13843",
      "title" => "Task 13843"
    })

    {:ok, issue_13843} = Issues.capture_issue(system_scope(), project, "Task 13843")

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_13843, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: task_id}.id, %{
        stage: :engineer,
        stage_state: :awaiting_approval
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")

    # The LiveView process issues the GitHub call, so lend it the stubs.

    Req.Test.allow(Rail.GitHub, self(), view.pid)

    Sandbox.allow(Repo, self(), view.pid)

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
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13844",
      "identifier" => "TSK-13844",
      "title" => "Task 13844"
    })

    {:ok, issue_13844} = Issues.capture_issue(system_scope(), project, "Task 13844")

    {:ok, %Task{id: busy_task_id}} = Pipeline.create_task(issue_13844, :product)

    {:ok, %Task{id: busy_task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: busy_task_id}.id, %{
        stage: :engineer,
        stage_state: :running
      })

    assert {:ok, busy_view, _html} = live(authed_conn, ~p"/tasks/#{busy_task_id}")
    assert has_element?(busy_view, "#action-cleanup[disabled]")
    render_hook(busy_view, "action_click", %{"action" => "cleanup"})
    refute has_element?(busy_view, "#confirm-cleanup-modal")
  end

  test "prompt send back modal flow (empty ignored, valid submits)", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_18",
        login: "task_detail_user_18",
        email: "task_detail_user_18@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    _scope = Scope.for_user(user)

    {:ok, %Project{id: _project_id}} =
      Projects.create_project(system_scope(), %{
        name: "Task Detail Project 13805",
        github_repo: "org/task-detail-13805",
        github_installation_id: 13_805,
        linear_team_id: "team_task_detail_13805",
        linear_team_key: "P13805",
        default_branch: "main",
        clone_path: "/tmp/repos/task-detail-13805",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13845",
      "identifier" => "TSK-13845",
      "title" => "Task 13845"
    })

    {:ok, issue_13845} = Issues.capture_issue(system_scope(), project, "Task 13845")

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_13845, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: task_id}.id, %{
        stage: :product,
        stage_state: :awaiting_approval
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")

    # The LiveView process issues the GitHub call, so lend it the stubs.

    Req.Test.allow(Rail.GitHub, self(), view.pid)

    Sandbox.allow(Repo, self(), view.pid)

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

  test "prompt send back to engineer modal flow (empty comment allowed)", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_19",
        login: "task_detail_user_19",
        email: "task_detail_user_19@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    _scope = Scope.for_user(user)

    {:ok, %Project{id: _project_id}} =
      Projects.create_project(system_scope(), %{
        name: "Task Detail Project 13806",
        github_repo: "org/task-detail-13806",
        github_installation_id: 13_806,
        linear_team_id: "team_task_detail_13806",
        linear_team_key: "P13806",
        default_branch: "main",
        clone_path: "/tmp/repos/task-detail-13806",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13846",
      "identifier" => "TSK-13846",
      "title" => "Task 13846"
    })

    {:ok, issue_13846} = Issues.capture_issue(system_scope(), project, "Task 13846")

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_13846, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: task_id}.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        pr_number: 404
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")

    # The LiveView process issues the GitHub call, so lend it the stubs.

    Req.Test.allow(Rail.GitHub, self(), view.pid)

    Sandbox.allow(Repo, self(), view.pid)

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
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13847",
      "identifier" => "TSK-13847",
      "title" => "Task 13847"
    })

    {:ok, issue_13847} = Issues.capture_issue(system_scope(), project, "Task 13847")

    {:ok, %Task{id: task_id_2}} = Pipeline.create_task(issue_13847, :product)

    {:ok, %Task{id: task_id_2}} =
      Pipeline.update_task(system_scope(), %Task{id: task_id_2}.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        pr_number: 405
      })

    assert {:ok, view_2, _html} = live(authed_conn, ~p"/tasks/#{task_id_2}")
    view_2 |> element("#action-send-back-to-engineer") |> render_click()
    view_2 |> form("#prompt-send-back-engineer-form", %{comment: "Tests failed in CI"}) |> render_submit()
    refute has_element?(view_2, "#prompt-send-back-engineer-modal")
  end

  test "prompt decline demo modal flow (empty reason defaults to 'Declined by human')", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_20",
        login: "task_detail_user_20",
        email: "task_detail_user_20@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    _scope = Scope.for_user(user)

    {:ok, %Project{id: _project_id}} =
      Projects.create_project(system_scope(), %{
        name: "Task Detail Project 13807",
        github_repo: "org/task-detail-13807",
        github_installation_id: 13_807,
        linear_team_id: "team_task_detail_13807",
        linear_team_key: "P13807",
        default_branch: "main",
        clone_path: "/tmp/repos/task-detail-13807",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13848",
      "identifier" => "TSK-13848",
      "title" => "Task 13848"
    })

    {:ok, issue_13848} = Issues.capture_issue(system_scope(), project, "Task 13848")

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_13848, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: task_id}.id, %{
        stage: :demo,
        stage_state: :failed
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")

    # The LiveView process issues the GitHub call, so lend it the stubs.

    Req.Test.allow(Rail.GitHub, self(), view.pid)

    Sandbox.allow(Repo, self(), view.pid)

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
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13849",
      "identifier" => "TSK-13849",
      "title" => "Task 13849"
    })

    {:ok, issue_13849} = Issues.capture_issue(system_scope(), project, "Task 13849")

    {:ok, %Task{id: task_id_2}} = Pipeline.create_task(issue_13849, :product)

    {:ok, %Task{id: task_id_2}} =
      Pipeline.update_task(system_scope(), %Task{id: task_id_2}.id, %{
        stage: :demo,
        stage_state: :failed
      })

    assert {:ok, view_2, _html} = live(authed_conn, ~p"/tasks/#{task_id_2}")
    view_2 |> element("#action-decline-demo") |> render_click()
    view_2 |> form("#prompt-decline-demo-form", %{reason: "Backend-only change"}) |> render_submit()
    refute has_element?(view_2, "#prompt-decline-demo-modal")
  end

  test "direct action buttons dispatch corresponding pipeline actions", %{conn: conn, project: project} do
    Req.Test.stub(Rail.GitHub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"token" => "test_token"}))
    end)

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_21",
        login: "task_detail_user_21",
        email: "task_detail_user_21@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    _scope = Scope.for_user(user)

    {:ok, %Project{id: _project_id}} =
      Projects.create_project(system_scope(), %{
        name: "Task Detail Project 13808",
        github_repo: "org/task-detail-13808",
        github_installation_id: 13_808,
        linear_team_id: "team_task_detail_13808",
        linear_team_key: "P13808",
        default_branch: "main",
        clone_path: "/tmp/repos/task-detail-13808",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    # 1. Approve & Approve skip design at product stage
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13850",
      "identifier" => "TSK-13850",
      "title" => "Task 13850"
    })

    {:ok, issue_13850} = Issues.capture_issue(system_scope(), project, "Task 13850")

    {:ok, %Task{id: prod_task_id}} = Pipeline.create_task(issue_13850, :product)

    {:ok, %Task{id: prod_task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: prod_task_id}.id, %{
        stage: :product,
        stage_state: :awaiting_approval
      })

    assert {:ok, prod_view, _html} = live(authed_conn, ~p"/tasks/#{prod_task_id}")
    assert has_element?(prod_view, "#action-approve", "Approve")
    assert has_element?(prod_view, "#action-approve-skip-design", "Approve, skip design")
    prod_view |> element("#action-approve") |> render_click()

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13851",
      "identifier" => "TSK-13851",
      "title" => "Task 13851"
    })

    {:ok, issue_13851} = Issues.capture_issue(system_scope(), project, "Task 13851")

    {:ok, %Task{id: prod_skip_task_id}} = Pipeline.create_task(issue_13851, :product)

    {:ok, %Task{id: prod_skip_task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: prod_skip_task_id}.id, %{
        stage: :product,
        stage_state: :awaiting_approval
      })

    assert {:ok, prod_skip_view, _html} = live(authed_conn, ~p"/tasks/#{prod_skip_task_id}")
    prod_skip_view |> element("#action-approve-skip-design") |> render_click()

    # 2. Skip to ready to merge at qa stage
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13852",
      "identifier" => "TSK-13852",
      "title" => "Task 13852"
    })

    {:ok, issue_13852} = Issues.capture_issue(system_scope(), project, "Task 13852")

    {:ok, %Task{id: qa_task_id}} = Pipeline.create_task(issue_13852, :product)

    {:ok, %Task{id: qa_task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: qa_task_id}.id, %{
        stage: :qa,
        stage_state: :awaiting_approval
      })

    assert {:ok, qa_view, _html} = live(authed_conn, ~p"/tasks/#{qa_task_id}")
    assert has_element?(qa_view, "#action-skip", "Skip")
    qa_view |> element("#action-skip") |> render_click()

    # 3. Retry on failed state
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13853",
      "identifier" => "TSK-13853",
      "title" => "Task 13853"
    })

    {:ok, issue_13853} = Issues.capture_issue(system_scope(), project, "Task 13853")

    {:ok, %Task{id: retry_task_id}} = Pipeline.create_task(issue_13853, :product)

    {:ok, %Task{id: retry_task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: retry_task_id}.id, %{
        stage: :engineer,
        stage_state: :failed
      })

    assert {:ok, retry_view, _html} = live(authed_conn, ~p"/tasks/#{retry_task_id}")
    assert has_element?(retry_view, "#action-retry", "Retry")
    retry_view |> element("#action-retry") |> render_click()

    # 4. Cancel on running task
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13854",
      "identifier" => "TSK-13854",
      "title" => "Task 13854"
    })

    {:ok, issue_13854} = Issues.capture_issue(system_scope(), project, "Task 13854")

    {:ok, %Task{id: running_task_id}} = Pipeline.create_task(issue_13854, :product)

    {:ok, %Task{id: running_task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: running_task_id}.id, %{
        stage: :engineer,
        stage_state: :running
      })

    assert {:ok, running_view, _html} = live(authed_conn, ~p"/tasks/#{running_task_id}")
    assert has_element?(running_view, "#action-cancel", "Cancel")
    running_view |> element("#action-cancel") |> render_click()

    # 5. Dispatch now on queued task
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13855",
      "identifier" => "TSK-13855",
      "title" => "Task 13855"
    })

    {:ok, issue_13855} = Issues.capture_issue(system_scope(), project, "Task 13855")

    {:ok, %Task{id: queued_task_id}} = Pipeline.create_task(issue_13855, :product)

    {:ok, %Task{id: queued_task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: queued_task_id}.id, %{
        stage: :engineer,
        stage_state: :queued,
        retry_after: DateTime.utc_now()
      })

    assert {:ok, queued_view, _html} = live(authed_conn, ~p"/tasks/#{queued_task_id}")
    assert has_element?(queued_view, "#action-dispatch", "Retry now")
    queued_view |> element("#action-dispatch") |> render_click()

    # 6. Unblock on blocked task without pending question
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13856",
      "identifier" => "TSK-13856",
      "title" => "Task 13856"
    })

    {:ok, issue_13856} = Issues.capture_issue(system_scope(), project, "Task 13856")

    {:ok, %Task{id: blocked_task_id}} = Pipeline.create_task(issue_13856, :product)

    {:ok, %Task{id: blocked_task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: blocked_task_id}.id, %{
        stage: :engineer,
        stage_state: :blocked,
        question_id: nil
      })

    assert {:ok, blocked_view, _html} = live(authed_conn, ~p"/tasks/#{blocked_task_id}")
    assert has_element?(blocked_view, "#action-unblock", "Unblock")
    blocked_view |> element("#action-unblock") |> render_click()

    # 7. Mark ready on draft PR
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13857",
      "identifier" => "TSK-13857",
      "title" => "Task 13857"
    })

    {:ok, issue_13857} = Issues.capture_issue(system_scope(), project, "Task 13857")

    {:ok, %Task{id: draft_task_id}} = Pipeline.create_task(issue_13857, :product)

    {:ok, %Task{id: draft_task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: draft_task_id}.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        pr_number: 505,
        pr_is_draft: true
      })

    assert {:ok, draft_view, _html} = live(authed_conn, ~p"/tasks/#{draft_task_id}")
    assert has_element?(draft_view, "#action-mark-ready", "Mark ready for review")
    draft_view |> element("#action-mark-ready") |> render_click()

    # 8. Rerecord demo on demo stage
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13858",
      "identifier" => "TSK-13858",
      "title" => "Task 13858"
    })

    {:ok, issue_13858} = Issues.capture_issue(system_scope(), project, "Task 13858")

    {:ok, %Task{id: demo_task_id}} = Pipeline.create_task(issue_13858, :product)

    {:ok, %Task{id: demo_task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: demo_task_id}.id, %{
        stage: :demo,
        stage_state: :failed
      })

    assert {:ok, demo_view, _html} = live(authed_conn, ~p"/tasks/#{demo_task_id}")
    assert has_element?(demo_view, "#action-rerecord-demo", "Re-record demo")
    demo_view |> element("#action-rerecord-demo") |> render_click()

    # 9. Design direction pick and recheck
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13859",
      "identifier" => "TSK-13859",
      "title" => "Task 13859"
    })

    {:ok, issue_13859} = Issues.capture_issue(system_scope(), project, "Task 13859")

    {:ok, %Task{id: design_task_id}} = Pipeline.create_task(issue_13859, :product)

    {:ok, %Task{id: design_task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: design_task_id}.id, %{
        stage: :design,
        stage_state: :awaiting_approval
      })

    design_scratch_14302 = Path.join("/tmp", "rail_design_scratch_#{System.unique_integer([:positive])}")
    design_dir_14302 = Path.join(design_scratch_14302, "design")
    File.mkdir_p!(design_dir_14302)
    on_exit(fn -> File.rm_rf(design_scratch_14302) end)

    File.write!(Path.join(design_dir_14302, "dir-a.png"), "fake png content")

    File.write!(
      Path.join(design_dir_14302, "manifest.json"),
      Jason.encode!(%{
        "canvasUrl" => "https://canvas.example.com/design-14302",
        "version" => 1,
        "pickedKey" => nil,
        "directions" => [
          %{"key" => "dir-a", "title" => "Direction Alpha", "notes" => "Notes", "stillPath" => "dir-a.png"}
        ]
      })
    )

    mock_design_uploads(1)

    {:ok, _design} =
      Artifacts.capture_design(system_scope(), design_task_id, design_scratch_14302, url_probe: fn _url -> true end)

    assert {:ok, design_view, _html} = live(authed_conn, ~p"/tasks/#{design_task_id}")
    assert has_element?(design_view, "#action-pick-design-dir-a", "Use Direction Alpha")
    design_view |> element("#action-pick-design-dir-a") |> render_click()

    # Design recheck
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13860",
      "identifier" => "TSK-13860",
      "title" => "Task 13860"
    })

    {:ok, issue_13860} = Issues.capture_issue(system_scope(), project, "Task 13860")

    {:ok, %Task{id: design_failed_id}} = Pipeline.create_task(issue_13860, :product)

    {:ok, %Task{id: design_failed_id}} =
      Pipeline.update_task(system_scope(), %Task{id: design_failed_id}.id, %{
        stage: :design,
        stage_state: :failed
      })

    assert {:ok, design_failed_view, _html} = live(authed_conn, ~p"/tasks/#{design_failed_id}")
    assert has_element?(design_failed_view, "#action-recheck-design", "Design is done")
    design_failed_view |> element("#action-recheck-design") |> render_click()
  end

  test "single-flight action locking, spinner, error clearing, and PubSub broadcasts", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_22",
        login: "task_detail_user_22",
        email: "task_detail_user_22@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    _scope = Scope.for_user(user)

    {:ok, %Project{id: _project_id}} =
      Projects.create_project(system_scope(), %{
        name: "Task Detail Project 13809",
        github_repo: "org/task-detail-13809",
        github_installation_id: 13_809,
        linear_team_id: "team_task_detail_13809",
        linear_team_key: "P13809",
        default_branch: "main",
        clone_path: "/tmp/repos/task-detail-13809",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13861",
      "identifier" => "TSK-13861",
      "title" => "Task 13861"
    })

    {:ok, issue_13861} = Issues.capture_issue(system_scope(), project, "Task 13861")

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_13861, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: task_id}.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        pr_number: 606,
        pr_is_draft: false,
        error: "Previous error message"
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")

    # The LiveView process issues the GitHub call, so lend it the stubs.

    Req.Test.allow(Rail.GitHub, self(), view.pid)

    Sandbox.allow(Repo, self(), view.pid)
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

  test "exercises TaskDetailLive action callbacks and modal error paths", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_23",
        login: "task_detail_user_23",
        email: "task_detail_user_23@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    {:ok, %Project{id: project_id}} =
      Projects.create_project(system_scope(), %{
        name: "Task Detail Project 13810",
        github_repo: "org/task-detail-13810",
        github_installation_id: 13_810,
        linear_team_id: "team_task_detail_13810",
        linear_team_key: "P13810",
        default_branch: "main",
        clone_path: "/tmp/repos/task-detail-13810",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13862",
      "identifier" => "TSK-13862",
      "title" => "Task 13862"
    })

    {:ok, issue_13862} = Issues.capture_issue(system_scope(), project, "Task 13862")

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_13862, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: task_id}.id, %{
        stage: :product,
        stage_state: :awaiting_approval
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")

    # The LiveView process issues the GitHub call, so lend it the stubs.

    Req.Test.allow(Rail.GitHub, self(), view.pid)

    Sandbox.allow(Repo, self(), view.pid)

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
       %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_24",
        login: "task_detail_user_24",
        email: "task_detail_user_24@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    {:ok, %Project{id: _project_id}} =
      Projects.create_project(system_scope(), %{
        name: "Task Detail Project 13811",
        github_repo: "org/task-detail-13811",
        github_installation_id: 13_811,
        linear_team_id: "team_task_detail_13811",
        linear_team_key: "P13811",
        default_branch: "main",
        clone_path: "/tmp/repos/task-detail-13811",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13863",
      "identifier" => "TSK-13863",
      "title" => "Task 13863"
    })

    {:ok, issue_13863} = Issues.capture_issue(system_scope(), project, "Task 13863")

    {:ok, task} = Pipeline.create_task(issue_13863, :product)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :blocked
      })

    {:ok, question} =
      Pipeline.register_question(task, %{
        prompt: "Which database adapter should be used?",
        options: ["PostgreSQL", "SQLite"],
        context_summary: "Found multiple adapters in repo"
      })

    _updated =
      task
      |> Ecto.Changeset.change(%{question_id: question.id})
      |> Repo.update!()

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
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13864",
      "identifier" => "TSK-13864",
      "title" => "Task 13864"
    })

    {:ok, issue_13864} = Issues.capture_issue(system_scope(), project, "Task 13864")

    {:ok, task_answer_fb} = Pipeline.create_task(issue_13864, :product)

    {:ok, task_answer_fb} =
      Pipeline.update_task(system_scope(), task_answer_fb.id, %{
        stage: :engineer,
        stage_state: :blocked
      })

    {:ok, q_fallback} =
      Pipeline.register_question(task_answer_fb, %{
        prompt: "Which port?",
        options: ["5432", "5433"]
      })

    _updated_fb =
      task_answer_fb
      |> Ecto.Changeset.change(%{question_id: q_fallback.id})
      |> Repo.update!()

    assert {:ok, view_fb, _html} = live(authed_conn, ~p"/tasks/#{task_answer_fb.id}")
    assert has_element?(view_fb, "#answer-field-card")
    render_hook(view_fb, "answer_question", %{"answer" => "5432"})
    refute has_element?(view_fb, "#answer-field-card")

    # 7. Test dismiss with explicit question_id param
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13865",
      "identifier" => "TSK-13865",
      "title" => "Task 13865"
    })

    {:ok, issue_13865} = Issues.capture_issue(system_scope(), project, "Task 13865")

    {:ok, task_dismiss_exp} = Pipeline.create_task(issue_13865, :product)

    {:ok, task_dismiss_exp} =
      Pipeline.update_task(system_scope(), task_dismiss_exp.id, %{
        stage: :engineer,
        stage_state: :blocked
      })

    {:ok, q2} =
      Pipeline.register_question(task_dismiss_exp, %{
        prompt: "Should we run seeds?",
        options: ["Yes", "No"]
      })

    _updated_2 =
      task_dismiss_exp
      |> Ecto.Changeset.change(%{question_id: q2.id})
      |> Repo.update!()

    assert {:ok, view2, _html} = live(authed_conn, ~p"/tasks/#{task_dismiss_exp.id}")
    assert has_element?(view2, "#answer-field-card")
    render_hook(view2, "dismiss_question", %{"question_id" => q2.id})
    refute has_element?(view2, "#answer-field-card")

    # 8. Test dismiss on a blocked task without explicit question_id param (uses fallback)
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13866",
      "identifier" => "TSK-13866",
      "title" => "Task 13866"
    })

    {:ok, issue_13866} = Issues.capture_issue(system_scope(), project, "Task 13866")

    {:ok, task_dismiss_fb} = Pipeline.create_task(issue_13866, :product)

    {:ok, task_dismiss_fb} =
      Pipeline.update_task(system_scope(), task_dismiss_fb.id, %{
        stage: :engineer,
        stage_state: :blocked
      })

    {:ok, q3} =
      Pipeline.register_question(task_dismiss_fb, %{
        prompt: "Run migrations?",
        options: ["Yes", "No"]
      })

    _updated_3 =
      task_dismiss_fb
      |> Ecto.Changeset.change(%{question_id: q3.id})
      |> Repo.update!()

    assert {:ok, view3, _html} = live(authed_conn, ~p"/tasks/#{task_dismiss_fb.id}")
    assert has_element?(view3, "#answer-field-card")
    render_hook(view3, "dismiss_question", %{})
    refute has_element?(view3, "#answer-field-card")

    # 7. Blocked task with invalid question_id gracefully sets pending_question to nil
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13867",
      "identifier" => "TSK-13867",
      "title" => "Task 13867"
    })

    {:ok, issue_13867} = Issues.capture_issue(system_scope(), project, "Task 13867")

    {:ok, bad_task} = Pipeline.create_task(issue_13867, :product)

    {:ok, bad_task} =
      Pipeline.update_task(system_scope(), bad_task.id, %{
        stage: :engineer,
        stage_state: :blocked,
        question_id: "qst_nonexistent_99"
      })

    assert {:ok, view_bad, _html} = live(authed_conn, ~p"/tasks/#{bad_task.id}")
    refute has_element?(view_bad, "#answer-field-card")
  end

  test "Conversation tab renders empty state when task has no runs", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_25",
        login: "task_detail_user_25",
        email: "task_detail_user_25@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    {:ok, %Project{id: _project_id}} =
      Projects.create_project(system_scope(), %{
        name: "Task Detail Project 13812",
        github_repo: "org/task-detail-13812",
        github_installation_id: 13_812,
        linear_team_id: "team_task_detail_13812",
        linear_team_key: "P13812",
        default_branch: "main",
        clone_path: "/tmp/repos/task-detail-13812",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13868",
      "identifier" => "TSK-13868",
      "title" => "Task 13868"
    })

    {:ok, issue_13868} = Issues.capture_issue(system_scope(), project, "Task 13868")

    {:ok, task} = Pipeline.create_task(issue_13868, :product)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :queued
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}?tab=conversation")

    assert has_element?(view, "#conversation-tab-root")
    assert has_element?(view, "#conversation-empty-state")
    assert has_element?(view, "#conversation-empty-state", "No role has run this task yet.")
  end

  test "Conversation tab handles role switching, raw log toggle, tool activity, and pubsub streaming", %{
    backend: backend,
    conn: conn,
    project: project
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_26",
        login: "task_detail_user_26",
        email: "task_detail_user_26@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    {:ok, %Project{id: project_id}} =
      Projects.create_project(system_scope(), %{
        name: "Task Detail Project 13813",
        github_repo: "org/task-detail-13813",
        github_installation_id: 13_813,
        linear_team_id: "team_task_detail_13813",
        linear_team_key: "P13813",
        default_branch: "main",
        clone_path: "/tmp/repos/task-detail-13813",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, role_arch} =
      Roles.create_role(system_scope(), project_id, %{
        backend_id: backend.id,
        name: "Architect",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 13816.",
        stage: :architect,
        icon_name: "pi-compass-tool"
      })

    {:ok, role_eng} =
      Roles.create_role(system_scope(), project_id, %{
        backend_id: backend.id,
        name: "Engineer",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 13817.",
        stage: :engineer,
        icon_name: "pi-code"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13869",
      "identifier" => "TSK-13869",
      "title" => "Task 13869"
    })

    {:ok, issue_13869} = Issues.capture_issue(system_scope(), project, "Task 13869")

    {:ok, task} = Pipeline.create_task(issue_13869, :product)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

    now = DateTime.utc_now()

    {:ok, _run_arch} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role_arch.id,
        status: :finished,
        started_at: DateTime.shift(now, minute: -10),
        completed_at: DateTime.shift(now, minute: -5),
        conversation_id: "conv_arch",
        output: "[human] Architect instructions\n[run] claude\nArchitecture design complete."
      })

    {:ok, run_eng} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role_eng.id,
        status: :running,
        started_at: DateTime.shift(now, second: -200),
        conversation_id: "conv_eng",
        output: "[human] Engineer instructions\n[run] claude\n[tool read_file] lib/app.ex\nWriting the code now."
      })

    {:ok, _run_custom} =
      Runs.create_role_run(%{
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

  test "Conversation tab chat input, delivery modal for running task, and dispatch options", %{
    backend: backend,
    conn: conn,
    project: project
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_27",
        login: "task_detail_user_27",
        email: "task_detail_user_27@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    {:ok, %Project{id: project_id}} =
      Projects.create_project(system_scope(), %{
        name: "Task Detail Project 13814",
        github_repo: "org/task-detail-13814",
        github_installation_id: 13_814,
        linear_team_id: "team_task_detail_13814",
        linear_team_key: "P13814",
        default_branch: "main",
        clone_path: "/tmp/repos/task-detail-13814",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, role_eng} =
      Roles.create_role(system_scope(), project_id, %{
        backend_id: backend.id,
        name: "Engineer",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 13818.",
        stage: :engineer,
        icon_name: "pi-code"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13870",
      "identifier" => "TSK-13870",
      "title" => "Task 13870"
    })

    {:ok, issue_13870} = Issues.capture_issue(system_scope(), project, "Task 13870")

    {:ok, task} = Pipeline.create_task(issue_13870, :product)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

    {:ok, _run_eng} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role_eng.id,
        status: :running,
        started_at: DateTime.utc_now(),
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
      |> Repo.update!()

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

  test "diff tab displays empty state when branch has no changes and refreshes", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_28",
        login: "task_detail_user_28",
        email: "task_detail_user_28@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    repo = create_temp_git_repo()

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13871",
      "identifier" => "TSK-13871",
      "title" => "Task 13871"
    })

    {:ok, issue_13871} = Issues.capture_issue(system_scope(), project, "Task 13871")

    {:ok, task} = Pipeline.create_task(issue_13871, :product)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
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

  test "diff tab loads changes, toggles viewed, and selects file in tree", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_29",
        login: "task_detail_user_29",
        email: "task_detail_user_29@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    repo = create_temp_git_repo()

    File.write!(Path.join(repo, "example.txt"), "hello world\nline two\n")

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13872",
      "identifier" => "TSK-13872",
      "title" => "Task 13872"
    })

    {:ok, issue_13872} = Issues.capture_issue(system_scope(), project, "Task 13872")

    {:ok, task} = Pipeline.create_task(issue_13872, :product)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
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

  test "diff tab expands gaps when clicking expand_gap", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_30",
        login: "task_detail_user_30",
        email: "task_detail_user_30@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
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

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13873",
      "identifier" => "TSK-13873",
      "title" => "Task 13873"
    })

    {:ok, issue_13873} = Issues.capture_issue(system_scope(), project, "Task 13873")

    {:ok, task} = Pipeline.create_task(issue_13873, :product)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
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

  test "exercises diff helper functions in TaskDetailLive", %{project: project} do
    scope = Scope.for_system()

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13874",
      "identifier" => "TSK-13874",
      "title" => "Task 13874"
    })

    {:ok, issue_13874} = Issues.capture_issue(system_scope(), project, "Task 13874")

    {:ok, task} = Pipeline.create_task(issue_13874, :product)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        worktree_path: "/tmp/rail-removed-worktree"
      })

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

  test "renders design panel when task has design attached", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_31",
        login: "task_detail_user_31",
        email: "task_detail_user_31@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13875",
      "identifier" => "TSK-13875",
      "title" => "Task 13875"
    })

    {:ok, issue_13875} = Issues.capture_issue(system_scope(), project, "Task 13875")

    {:ok, task} = Pipeline.create_task(issue_13875, :product)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        owner_user_id: user.id,
        stage: :engineer,
        stage_state: :running
      })

    design_scratch_14303 = Path.join("/tmp", "rail_design_scratch_#{System.unique_integer([:positive])}")
    design_dir_14303 = Path.join(design_scratch_14303, "design")
    File.mkdir_p!(design_dir_14303)
    on_exit(fn -> File.rm_rf(design_scratch_14303) end)

    File.write!(Path.join(design_dir_14303, "dir-a.png"), "fake png content")

    File.write!(
      Path.join(design_dir_14303, "manifest.json"),
      Jason.encode!(%{
        "canvasUrl" => "https://canvas.example.com/design-14303",
        "version" => 2,
        "pickedKey" => nil,
        "directions" => [
          %{"key" => "dir-a", "title" => "Direction Alpha", "notes" => "Notes", "stillPath" => "dir-a.png"}
        ]
      })
    )

    mock_design_uploads(1)

    {:ok, _design} =
      Artifacts.capture_design(system_scope(), task, design_scratch_14303, url_probe: fn _url -> true end)

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#design-panel")
    assert has_element?(view, "#design-panel-title", "Design directions")
    assert has_element?(view, "#design-version-pill", "v2")
    assert has_element?(view, "#design-direction-card-dir-a")
    assert has_element?(view, "#design-direction-title-dir-a", "Direction Alpha")
    assert has_element?(view, "#design-canvas-link")
  end

  test "renders demo panel when task has demo attached", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_32",
        login: "task_detail_user_32",
        email: "task_detail_user_32@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13876",
      "identifier" => "TSK-13876",
      "title" => "Task 13876"
    })

    {:ok, issue_13876} = Issues.capture_issue(system_scope(), project, "Task 13876")

    {:ok, task} = Pipeline.create_task(issue_13876, :product)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        owner_user_id: user.id,
        stage: :engineer,
        stage_state: :running
      })

    demo_scratch_14304 = Path.join("/tmp", "rail_demo_scratch_#{System.unique_integer([:positive])}")
    demo_dir_14304 = Path.join(demo_scratch_14304, "demo")
    File.mkdir_p!(demo_dir_14304)
    on_exit(fn -> File.rm_rf(demo_scratch_14304) end)

    File.write!(Path.join(demo_dir_14304, "frame-1.png"), "fake demo frame")

    File.write!(
      Path.join(demo_dir_14304, "manifest.json"),
      Jason.encode!(%{
        "version" => 1,
        "outcome" => "recorded",
        "segments" => [
          %{
            "criterionIndex" => 1,
            "criterion" => "First criterion",
            "outcome" => "recorded",
            "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
          }
        ]
      })
    )

    mock_demo_uploads(1)

    LinearMock.mock_create_comment_success(%{
      "id" => "cmt_demo_14304",
      "body" => "Demo",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    {:ok, _demo} =
      Artifacts.capture_demo(system_scope(), task, demo_scratch_14304)

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#demo-panel")
    assert has_element?(view, "#demo-panel-title", "Recorded demo")
    assert has_element?(view, "#demo-version-pill", "v1")
    assert has_element?(view, "#demo-recorded-count-pill", "1/1 recorded")
    assert has_element?(view, "#demo-play-all-btn")
    refute has_element?(view, "#no-demo-banner")
  end

  test "renders no-demo banner when stage is ready_to_merge and no demo exists", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_33",
        login: "task_detail_user_33",
        email: "task_detail_user_33@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13877",
      "identifier" => "TSK-13877",
      "title" => "Task 13877"
    })

    {:ok, issue_13877} = Issues.capture_issue(system_scope(), project, "Task 13877")

    {:ok, task} = Pipeline.create_task(issue_13877, :product)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
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

  test "opens demo player modal, navigates controls, and closes modal", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_detail_34",
        login: "task_detail_user_34",
        email: "task_detail_user_34@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13878",
      "identifier" => "TSK-13878",
      "title" => "Task 13878"
    })

    {:ok, issue_13878} = Issues.capture_issue(system_scope(), project, "Task 13878")

    {:ok, task} = Pipeline.create_task(issue_13878, :product)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        owner_user_id: user.id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: "/tmp/fake-worktree"
      })

    demo_scratch_14305 = Path.join("/tmp", "rail_demo_scratch_#{System.unique_integer([:positive])}")
    demo_dir_14305 = Path.join(demo_scratch_14305, "demo")
    File.mkdir_p!(demo_dir_14305)
    on_exit(fn -> File.rm_rf(demo_scratch_14305) end)

    File.write!(Path.join(demo_dir_14305, "frame-1.png"), "fake demo frame")
    File.write!(Path.join(demo_dir_14305, "frame-2.png"), "fake demo frame")
    File.write!(Path.join(demo_dir_14305, "frame-3.png"), "fake demo frame")

    File.write!(
      Path.join(demo_dir_14305, "manifest.json"),
      Jason.encode!(%{
        "version" => 1,
        "outcome" => "recorded",
        "segments" => [
          %{
            "criterionIndex" => 1,
            "criterion" => "First criterion",
            "outcome" => "recorded",
            "frames" => [
              %{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Caption 1"},
              %{"path" => "frame-2.png", "holdMs" => 1000, "caption" => "Caption 2"}
            ]
          },
          %{
            "criterionIndex" => 2,
            "criterion" => "Second criterion",
            "outcome" => "recorded",
            "frames" => [%{"path" => "frame-3.png", "holdMs" => 1000, "caption" => "Caption 3"}]
          }
        ]
      })
    )

    mock_demo_uploads(3)

    LinearMock.mock_create_comment_success(%{
      "id" => "cmt_demo_14305",
      "body" => "Demo",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    {:ok, _demo} =
      Artifacts.capture_demo(system_scope(), task, demo_scratch_14305)

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

  test "exercises demo player and rerecord_demo unit events on TaskDetailLive", %{project: project} do
    scope = Scope.for_system()

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13879",
      "identifier" => "TSK-13879",
      "title" => "Task 13879"
    })

    {:ok, issue_13879} = Issues.capture_issue(system_scope(), project, "Task 13879")

    {:ok, task} = Pipeline.create_task(issue_13879, :product)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        worktree_path: "/tmp/rail-removed-worktree"
      })

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
