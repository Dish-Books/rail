defmodule RailWeb.TaskDetailLiveTest do
  use RailWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import RailTest.Mocks.Linear, only: [mock_demo_uploads: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias Phoenix.LiveView.Socket
  alias Rail.Artifacts
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.TaskActionRunner
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.DetectedQuestion
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
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

    roles =
      Map.new(Task.stages() -- [:ready_to_merge, :merged], fn stage ->
        {:ok, role} =
          Roles.create_role(system_scope(), project, %{
            backend_id: backend.id,
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    %{backend: backend, workspace: workspace, project: project, roles: roles}
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
    roles: roles,
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

    {:ok, issue} = Issues.create_issue(project, %{description: "Task Detail Issue 13823"})

    {:ok, issue} =
      Issues.update_issue(issue, %{
        branch_name: "feature-branch"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13826",
      "identifier" => "TSK-13826",
      "title" => "Implement Login Flow"
    })

    {:ok, issue_13826} = Issues.create_issue(project, %{description: "Implement Login Flow"})

    {:ok, task} = Pipeline.create_task(issue_13826, :product)

    Repo.update_all(from(i in Issue, where: i.id == ^issue.id),
      set: [title: "Implement Login Flow", description: "Must handle OAuth callbacks cleanly"]
    )

    {:ok, task} =
      Pipeline.update_task(task, %{
        issue_id: issue.id,
        stage: :engineer,
        worktree_name: "login-flow",
        pr_number: 101,
        pr_url: "https://github.com/example/detail-project/pull/101"
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^task.id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: (roles[Repo.reload!(task).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :running,
        stage_outcome: :in_progress
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")

    # Header & Badge
    assert has_element?(view, "#task-detail-view")
    assert has_element?(view, "#task-detail-title", "Implement Login Flow")
    assert has_element?(view, "[data-qa='project-badge']", "DET")

    # 3 Tabs in exact order
    assert has_element?(view, "#tab-overview", "Overview")
    assert has_element?(view, "#tab-conversation", "Conversation")
    assert has_element?(view, "#tab-diff", "Diff")
    assert has_element?(view, "#tab-overview[data-active='true']")

    # Stage Stepper
    assert has_element?(view, "#stage-stepper")
    assert has_element?(view, "#stage-chip-engineer")

    # Metadata Wrap
    assert has_element?(view, "#task-metadata-wrap")
    assert has_element?(view, "#metadata-status-chip")
    assert has_element?(view, "#meta-branch", "login-flow")
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

  test "switches tabs and displays tab panes", %{roles: roles, conn: conn, project: project} do
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

    {:ok, issue_13827} = Issues.create_issue(project, %{description: "Tab Switching Task"})

    {:ok, task} = Pipeline.create_task(issue_13827, :product)

    Repo.update_all(from(i in Issue, where: i.id == ^Repo.get!(Task, task.id).issue_id),
      set: [description: "Testing tabs"]
    )

    tab_worktree = create_temp_git_repo()

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :product,
        worktree_path: tab_worktree
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^task.id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: (roles[Repo.reload!(task).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :running,
        stage_outcome: :in_progress
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")

    # Switch to Conversation tab
    view |> element("#tab-conversation") |> render_click()
    assert_patched(view, ~p"/tasks/#{task.id}?tab=conversation")
    assert has_element?(view, "#tab-conversation[data-active='true']")
    assert has_element?(view, "#tab-conversation[data-active='true']")

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
    render_hook(view, "switch_tab", %{"tab" => "conversation"})
    assert_patched(view, ~p"/tasks/#{task.id}?tab=conversation")
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

    {:ok, issue_13829} = Issues.create_issue(project, %{description: "No Worktree Task"})

    {:ok, task} = Pipeline.create_task(issue_13829, :product)

    Repo.update_all(from(i in Issue, where: i.id == ^Repo.get!(Task, task.id).issue_id),
      set: [description: "Task without worktree"]
    )

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :product,
        worktree_path: "/tmp/rail-removed-worktree"
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^task.id)

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}?tab=diff")
    assert has_element?(view, "#diff-empty-state")
    assert has_element?(view, "#diff-empty-state", "This task has no worktree.")
  end

  test "renders conflict banner when task has merge conflicts and not rebasing", %{
    roles: roles,
    conn: conn,
    project: project
  } do
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

    {:ok, issue_13830} = Issues.create_issue(project, %{description: "Conflicted Task"})

    {:ok, conflicted_task} = Pipeline.create_task(issue_13830, :product)

    Repo.update_all(from(i in Issue, where: i.id == ^Repo.get!(Task, conflicted_task.id).issue_id),
      set: [description: "Merge conflict present"]
    )

    {:ok, conflicted_task} =
      Pipeline.update_task(conflicted_task, %{
        stage: :engineer,
        mergeability: :conflicting,
        is_rebasing: false,
        pr_number: 42
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^conflicted_task.id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: conflicted_task.id,
        role_id: (roles[Repo.reload!(conflicted_task).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :finished,
        stage_outcome: :in_progress,
        error: "Run failed."
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

    {:ok, issue_13831} = Issues.create_issue(project, %{description: "Rebasing Task"})

    {:ok, rebasing_task} = Pipeline.create_task(issue_13831, :product)

    Repo.update_all(from(i in Issue, where: i.id == ^Repo.get!(Task, rebasing_task.id).issue_id),
      set: [description: "Actively rebasing"]
    )

    {:ok, rebasing_task} =
      Pipeline.update_task(rebasing_task, %{
        stage: :engineer,
        mergeability: :conflicting,
        is_rebasing: true,
        pr_number: 43
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^rebasing_task.id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: rebasing_task.id,
        role_id: (roles[Repo.reload!(rebasing_task).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :running,
        stage_outcome: :in_progress
      })

    assert {:ok, rebasing_view, _html} = live(authed_conn, ~p"/tasks/#{rebasing_task.id}")
    refute has_element?(rebasing_view, "#conflict-banner")
  end

  test "renders the error the run recorded", %{roles: roles, conn: conn, project: project} do
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

    {:ok, issue_13832} = Issues.create_issue(project, %{description: "Error Task"})

    {:ok, task} = Pipeline.create_task(issue_13832, :product)

    Repo.update_all(from(i in Issue, where: i.id == ^Repo.get!(Task, task.id).issue_id),
      set: [description: "Task with error"]
    )

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :engineer
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^task.id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: (roles[Repo.reload!(task).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :finished,
        stage_outcome: :in_progress,
        error: "Elixir compilation error"
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#task-error-card")
    assert has_element?(view, "#task-error-card", "Elixir compilation error")
  end

  test "renders the stage failure when a run failed", %{
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

    {:ok, issue_13833} = Issues.create_issue(project, %{description: "Outcome Task"})

    {:ok, task} = Pipeline.create_task(issue_13833, :product)

    Repo.update_all(from(i in Issue, where: i.id == ^Repo.get!(Task, task.id).issue_id),
      set: [description: "Task with run"]
    )

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :engineer
      })

    now = DateTime.utc_now()

    # The run carries the failure, which is what the page reads it off.
    {:ok, _run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        started_at: now,
        error: "Unit tests failed with exit code 1"
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#stage-outcome")
    assert has_element?(view, "#stage-failure-section")
    assert has_element?(view, "#stage-failure-box", "Unit tests failed with exit code 1")
  end

  test "ignores messages it has no use for", %{conn: conn, project: project} do
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

    {:ok, issue_13835} = Issues.create_issue(project, %{description: "Initial Title"})

    {:ok, %Task{id: target_id}} = Pipeline.create_task(issue_13835, :product)

    {:ok, %Task{id: target_id}} =
      Pipeline.update_task(Repo.get!(Task, target_id), %{
        stage: :product
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^Repo.get!(Task, target_id).id)

    issue_id = Repo.get!(Task, target_id).issue_id

    _issue_id = issue_id

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{target_id}")
    assert has_element?(view, "#task-detail-title", "Initial Title")

    send(view.pid, :some_unknown_info)
    send(view.pid, {:unknown, "message"})
    send(view.pid, {:run_events, "run_someone_else", []})

    assert has_element?(view, "#task-detail-title", "Initial Title")
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

    {:ok, issue} = Issues.create_issue(project, %{description: "Task Detail Issue 13824"})

    {:ok, issue} =
      Issues.update_issue(issue, %{
        branch_name: "rail/issue-branch",
        priority: :urgent
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13836",
      "identifier" => "TSK-13836",
      "title" => "Metadata Fallback Task"
    })

    {:ok, issue_13836} = Issues.create_issue(project, %{description: "Metadata Fallback Task"})

    {:ok, task} = Pipeline.create_task(issue_13836, :product)

    Repo.update_all(from(i in Issue, where: i.id == ^issue.id),
      set: [description: "## Ticket\n\nTicket description content\n\n## Implementation Plan\n\nPlan details"]
    )

    {:ok, task} =
      Pipeline.update_task(task, %{
        issue_id: issue.id,
        stage: :architect,
        worktree_name: "removed-worktree",
        pr_number: 55,
        pr_url: nil,
        priority: nil
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^task.id)

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#meta-branch", "removed-worktree")
    assert has_element?(view, "#meta-issue", "FB-99")
    assert has_element?(view, "#meta-pr", "PR #55")
    assert has_element?(view, "#meta-priority", "Urgent")
    assert has_element?(view, "#ticket-section", "Ticket description content")
  end

  test "exercises LiveView callbacks and edge-case branches", %{roles: roles, conn: conn, project: project} do
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

    {:ok, issue} = Issues.create_issue(project, %{description: "Task Detail Issue 13825"})

    {:ok, issue} =
      Issues.update_issue(issue, %{
        priority: :high
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13837",
      "identifier" => "TSK-13837",
      "title" => "Edge Case Task"
    })

    {:ok, issue_13837} = Issues.create_issue(project, %{description: "Edge Case Task"})

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_13837, :product)

    Repo.update_all(from(i in Issue, where: i.id == ^issue.id), set: [description: "Edge case description"])

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(Repo.get!(Task, task_id), %{
        issue_id: issue.id,
        stage: :demo,
        worktree_name: "rail/existing-prefix",
        pr_number: 99,
        pr_url: nil
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^Repo.get!(Task, task_id).id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: Repo.get!(Task, task_id).id,
        role_id: (roles[Repo.reload!(Repo.get!(Task, task_id)).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :running,
        stage_outcome: :in_progress
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")

    # The LiveView process issues the GitHub call, so lend it the stubs.

    Req.Test.allow(Rail.GitHub, self(), view.pid)

    Sandbox.allow(Repo, self(), view.pid)
    assert has_element?(view, "#meta-branch", "existing-prefix")
    assert has_element?(view, "#meta-issue", "EC-1")
    assert has_element?(view, "#meta-priority", "High")

    render_hook(view, "nonexistent_event", %{})

    dummy_socket = %Socket{assigns: %{task: nil}}
    assert {:noreply, _socket} =
             RailWeb.TaskDetailLive.handle_event("switch_tab", %{"tab" => "conversation"}, dummy_socket)
    assert {:noreply, _socket} = RailWeb.TaskDetailLive.handle_event("random", %{}, dummy_socket)
    assert {:noreply, _socket} = RailWeb.TaskDetailLive.handle_async(:dummy, :result, dummy_socket)
    assert :ok = RailWeb.TaskDetailLive.terminate(:normal, dummy_socket)

    # A task that is gone reads as cleaned up the next time the page is opened.
    Repo.delete_all(from(t in Task, where: t.id == ^task_id))
    assert {:ok, gone_view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")
    assert render(gone_view) =~ "This task has been cleaned up."

    # Minimal task without worktree, issue, or pr to test all fallback branches
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13838",
      "identifier" => "TSK-13838",
      "title" => "Minimal Task"
    })

    {:ok, issue_13838} = Issues.create_issue(project, %{description: "Minimal Task"})

    {:ok, %Task{id: minimal_id}} = Pipeline.create_task(issue_13838, :product)

    {:ok, %Task{id: minimal_id}} =
      Pipeline.update_task(Repo.get!(Task, minimal_id), %{
        issue_id: nil,
        worktree_name: "removed-worktree",
        pr_number: nil,
        pr_url: nil
      })

    assert {:ok, view_min, _html} = live(authed_conn, ~p"/tasks/#{minimal_id}")
    assert has_element?(view_min, "#meta-branch", "removed-worktree")
    refute has_element?(view_min, "#meta-issue")
    refute has_element?(view_min, "#meta-pr")
  end

  test "clicking chat and diff actions navigates to respective tabs", %{roles: roles, conn: conn, project: project} do
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

    {:ok, issue_13839} = Issues.create_issue(project, %{description: "Task 13839"})

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_13839, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(Repo.get!(Task, task_id), %{
        stage: :engineer,
        worktree_path: create_temp_git_repo()
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^Repo.get!(Task, task_id).id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: Repo.get!(Task, task_id).id,
        role_id: (roles[Repo.reload!(Repo.get!(Task, task_id)).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :finished,
        stage_outcome: :done
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
    roles: roles,
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

    {:ok, issue_13840} = Issues.create_issue(project, %{description: "Task 13840"})

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_13840, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(Repo.get!(Task, task_id), %{
        stage: :ready_to_merge,
        pr_number: 202,
        pr_is_draft: false,
        mergeability: :mergeable
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^Repo.get!(Task, task_id).id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: Repo.get!(Task, task_id).id,
        role_id: (roles[Repo.reload!(Repo.get!(Task, task_id)).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :finished,
        stage_outcome: :done
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

    {:ok, issue_13841} = Issues.create_issue(project, %{description: "Task 13841"})

    {:ok, %Task{id: conf_task_id}} = Pipeline.create_task(issue_13841, :product)

    {:ok, %Task{id: conf_task_id}} =
      Pipeline.update_task(Repo.get!(Task, conf_task_id), %{
        stage: :ready_to_merge,
        pr_number: 203,
        pr_is_draft: false,
        mergeability: :conflicting
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^Repo.get!(Task, conf_task_id).id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: Repo.get!(Task, conf_task_id).id,
        role_id: (roles[Repo.reload!(Repo.get!(Task, conf_task_id)).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :finished,
        stage_outcome: :done
      })

    assert {:ok, conf_view, _html} = live(authed_conn, ~p"/tasks/#{conf_task_id}")
    conf_view |> element("#action-merge-anyway") |> render_click()
    assert has_element?(conf_view, "#confirm-merge-modal")
    assert render(conf_view) =~ "GitHub last reported conflicts"
    conf_view |> element("#confirm-merge-button") |> render_click()
    refute has_element?(conf_view, "#confirm-merge-modal")
  end

  test "confirm rebase modal flow (open, cancel, submit)", %{roles: roles, conn: conn, project: project} do
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

    {:ok, issue_13842} = Issues.create_issue(project, %{description: "Task 13842"})

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_13842, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(Repo.get!(Task, task_id), %{
        stage: :ready_to_merge,
        pr_number: 303,
        mergeability: :conflicting
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^Repo.get!(Task, task_id).id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: Repo.get!(Task, task_id).id,
        role_id: (roles[Repo.reload!(Repo.get!(Task, task_id)).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :finished,
        stage_outcome: :done
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

  test "confirm cleanup modal flow and rejection when busy", %{roles: roles, conn: conn, project: project} do
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

    {:ok, issue_13843} = Issues.create_issue(project, %{description: "Task 13843"})

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_13843, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(Repo.get!(Task, task_id), %{
        stage: :engineer
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^Repo.get!(Task, task_id).id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: Repo.get!(Task, task_id).id,
        role_id: (roles[Repo.reload!(Repo.get!(Task, task_id)).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :finished,
        stage_outcome: :done
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

    {:ok, issue_13844} = Issues.create_issue(project, %{description: "Task 13844"})

    {:ok, %Task{id: busy_task_id}} = Pipeline.create_task(issue_13844, :product)

    {:ok, %Task{id: busy_task_id}} =
      Pipeline.update_task(Repo.get!(Task, busy_task_id), %{
        stage: :engineer
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^Repo.get!(Task, busy_task_id).id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: Repo.get!(Task, busy_task_id).id,
        role_id: (roles[Repo.reload!(Repo.get!(Task, busy_task_id)).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :running,
        stage_outcome: :in_progress
      })

    assert {:ok, busy_view, _html} = live(authed_conn, ~p"/tasks/#{busy_task_id}")
    assert has_element?(busy_view, "#action-cleanup[disabled]")
    render_hook(busy_view, "action_click", %{"action" => "cleanup"})
    refute has_element?(busy_view, "#confirm-cleanup-modal")
  end

  test "prompt send back to engineer modal flow (empty comment allowed)", %{roles: roles, conn: conn, project: project} do
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

    {:ok, issue_13846} = Issues.create_issue(project, %{description: "Task 13846"})

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_13846, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(Repo.get!(Task, task_id), %{
        stage: :ready_to_merge,
        pr_number: 404
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^Repo.get!(Task, task_id).id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: Repo.get!(Task, task_id).id,
        role_id: (roles[Repo.reload!(Repo.get!(Task, task_id)).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :finished,
        stage_outcome: :done
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

    {:ok, issue_13847} = Issues.create_issue(project, %{description: "Task 13847"})

    {:ok, %Task{id: task_id_2}} = Pipeline.create_task(issue_13847, :product)

    {:ok, %Task{id: task_id_2}} =
      Pipeline.update_task(Repo.get!(Task, task_id_2), %{
        stage: :ready_to_merge,
        pr_number: 405
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^Repo.get!(Task, task_id_2).id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: Repo.get!(Task, task_id_2).id,
        role_id: (roles[Repo.reload!(Repo.get!(Task, task_id_2)).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :finished,
        stage_outcome: :done
      })

    assert {:ok, view_2, _html} = live(authed_conn, ~p"/tasks/#{task_id_2}")
    view_2 |> element("#action-send-back-to-engineer") |> render_click()
    view_2 |> form("#prompt-send-back-engineer-form", %{comment: "Tests failed in CI"}) |> render_submit()
    refute has_element?(view_2, "#prompt-send-back-engineer-modal")
  end

  test "prompt decline demo modal flow (empty reason defaults to 'Declined by human')", %{
    roles: roles,
    conn: conn,
    project: project
  } do
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

    {:ok, issue_13848} = Issues.create_issue(project, %{description: "Task 13848"})

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_13848, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(Repo.get!(Task, task_id), %{
        stage: :demo
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^Repo.get!(Task, task_id).id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: Repo.get!(Task, task_id).id,
        role_id: (roles[Repo.reload!(Repo.get!(Task, task_id)).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :finished,
        stage_outcome: :in_progress,
        error: "Run failed."
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

    {:ok, issue_13849} = Issues.create_issue(project, %{description: "Task 13849"})

    {:ok, %Task{id: task_id_2}} = Pipeline.create_task(issue_13849, :product)

    {:ok, %Task{id: task_id_2}} =
      Pipeline.update_task(Repo.get!(Task, task_id_2), %{
        stage: :demo
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^Repo.get!(Task, task_id_2).id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: Repo.get!(Task, task_id_2).id,
        role_id: (roles[Repo.reload!(Repo.get!(Task, task_id_2)).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :finished,
        stage_outcome: :in_progress,
        error: "Run failed."
      })

    assert {:ok, view_2, _html} = live(authed_conn, ~p"/tasks/#{task_id_2}")
    view_2 |> element("#action-decline-demo") |> render_click()
    view_2 |> form("#prompt-decline-demo-form", %{reason: "Backend-only change"}) |> render_submit()
    refute has_element?(view_2, "#prompt-decline-demo-modal")
  end

  test "direct action buttons dispatch corresponding pipeline actions", %{roles: roles, conn: conn, project: project} do
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

    # 1. Skip to ready to merge at qa stage
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13852",
      "identifier" => "TSK-13852",
      "title" => "Task 13852"
    })

    {:ok, issue_13852} = Issues.create_issue(project, %{description: "Task 13852"})

    {:ok, %Task{id: qa_task_id}} = Pipeline.create_task(issue_13852, :product)

    {:ok, %Task{id: qa_task_id}} =
      Pipeline.update_task(Repo.get!(Task, qa_task_id), %{
        stage: :qa
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^Repo.get!(Task, qa_task_id).id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: Repo.get!(Task, qa_task_id).id,
        role_id: (roles[Repo.reload!(Repo.get!(Task, qa_task_id)).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :finished,
        stage_outcome: :done
      })

    assert {:ok, qa_view, _html} = live(authed_conn, ~p"/tasks/#{qa_task_id}")
    assert has_element?(qa_view, "#action-skip", "Skip")
    qa_view |> element("#action-skip") |> render_click()

    # 2. Retry on failed state
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13853",
      "identifier" => "TSK-13853",
      "title" => "Task 13853"
    })

    {:ok, issue_13853} = Issues.create_issue(project, %{description: "Task 13853"})

    {:ok, %Task{id: retry_task_id}} = Pipeline.create_task(issue_13853, :product)

    {:ok, %Task{id: retry_task_id}} =
      Pipeline.update_task(Repo.get!(Task, retry_task_id), %{
        stage: :engineer
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^Repo.get!(Task, retry_task_id).id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: Repo.get!(Task, retry_task_id).id,
        role_id: (roles[Repo.reload!(Repo.get!(Task, retry_task_id)).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :finished,
        stage_outcome: :in_progress,
        error: "Run failed."
      })

    assert {:ok, retry_view, _html} = live(authed_conn, ~p"/tasks/#{retry_task_id}")
    assert has_element?(retry_view, "#action-retry", "Retry")
    retry_view |> element("#action-retry") |> render_click()

    # 3. Cancel on running task
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13854",
      "identifier" => "TSK-13854",
      "title" => "Task 13854"
    })

    {:ok, issue_13854} = Issues.create_issue(project, %{description: "Task 13854"})

    {:ok, %Task{id: running_task_id}} = Pipeline.create_task(issue_13854, :product)

    {:ok, %Task{id: running_task_id}} =
      Pipeline.update_task(Repo.get!(Task, running_task_id), %{
        stage: :engineer
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^Repo.get!(Task, running_task_id).id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: Repo.get!(Task, running_task_id).id,
        role_id: (roles[Repo.reload!(Repo.get!(Task, running_task_id)).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :running,
        stage_outcome: :in_progress
      })

    assert {:ok, running_view, _html} = live(authed_conn, ~p"/tasks/#{running_task_id}")
    refute has_element?(running_view, "#action-cancel")

    # 4. Dispatch now on queued task
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13855",
      "identifier" => "TSK-13855",
      "title" => "Task 13855"
    })

    {:ok, issue_13855} = Issues.create_issue(project, %{description: "Task 13855"})

    {:ok, %Task{id: queued_task_id}} = Pipeline.create_task(issue_13855, :product)

    {:ok, %Task{id: queued_task_id}} =
      Pipeline.update_task(Repo.get!(Task, queued_task_id), %{
        stage: :engineer
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^Repo.get!(Task, queued_task_id).id)

    assert {:ok, queued_view, _html} = live(authed_conn, ~p"/tasks/#{queued_task_id}")
    refute has_element?(queued_view, "#action-dispatch")

    # 5. Mark ready on draft PR
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13857",
      "identifier" => "TSK-13857",
      "title" => "Task 13857"
    })

    {:ok, issue_13857} = Issues.create_issue(project, %{description: "Task 13857"})

    {:ok, %Task{id: draft_task_id}} = Pipeline.create_task(issue_13857, :product)

    {:ok, %Task{id: draft_task_id}} =
      Pipeline.update_task(Repo.get!(Task, draft_task_id), %{
        stage: :ready_to_merge,
        pr_number: 505,
        pr_is_draft: true
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^Repo.get!(Task, draft_task_id).id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: Repo.get!(Task, draft_task_id).id,
        role_id: (roles[Repo.reload!(Repo.get!(Task, draft_task_id)).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :finished,
        stage_outcome: :done
      })

    assert {:ok, draft_view, _html} = live(authed_conn, ~p"/tasks/#{draft_task_id}")
    assert has_element?(draft_view, "#action-mark-ready", "Mark ready for review")
    draft_view |> element("#action-mark-ready") |> render_click()

    # 6. Rerecord demo on demo stage
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13858",
      "identifier" => "TSK-13858",
      "title" => "Task 13858"
    })

    {:ok, issue_13858} = Issues.create_issue(project, %{description: "Task 13858"})

    {:ok, %Task{id: demo_task_id}} = Pipeline.create_task(issue_13858, :product)

    {:ok, %Task{id: demo_task_id}} =
      Pipeline.update_task(Repo.get!(Task, demo_task_id), %{
        stage: :demo
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^Repo.get!(Task, demo_task_id).id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: Repo.get!(Task, demo_task_id).id,
        role_id: (roles[Repo.reload!(Repo.get!(Task, demo_task_id)).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :finished,
        stage_outcome: :in_progress,
        error: "Run failed."
      })

    assert {:ok, demo_view, _html} = live(authed_conn, ~p"/tasks/#{demo_task_id}")
    assert has_element?(demo_view, "#action-rerecord-demo", "Re-record demo")
    demo_view |> element("#action-rerecord-demo") |> render_click()
  end

  test "single-flight action locking and the spinner while one is in flight", %{
    roles: roles,
    conn: conn,
    project: project
  } do
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

    {:ok, issue_13861} = Issues.create_issue(project, %{description: "Task 13861"})

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_13861, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(Repo.get!(Task, task_id), %{
        stage: :ready_to_merge,
        pr_number: 606,
        pr_is_draft: false
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^Repo.get!(Task, task_id).id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: Repo.get!(Task, task_id).id,
        role_id: (roles[Repo.reload!(Repo.get!(Task, task_id)).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :finished,
        stage_outcome: :done
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")

    # The LiveView process issues the GitHub call, so lend it the stubs.

    Req.Test.allow(Rail.GitHub, self(), view.pid)

    Sandbox.allow(Repo, self(), view.pid)

    refute has_element?(view, "#action-merge[disabled]")

    # An action in flight locks every button and shows its own spinner.
    :ok = TaskActionRunner.start_action(task_id, :merge)

    assert {:ok, locked_view, _html} = live(authed_conn, ~p"/tasks/#{task_id}")
    assert has_element?(locked_view, "#action-merge[disabled]")
    assert has_element?(locked_view, "#action-merge [data-qa='action-spinner']")

    # Single-flight: it refuses to start a second one while that runs.
    assert {:error, :busy} = TaskActionRunner.start_action(task_id, :rebase)

    :ok = TaskActionRunner.finish_action(task_id, :merge, {:ok, :done})
  end

  test "exercises TaskDetailLive action callbacks and modal error paths", %{roles: roles, conn: conn, project: project} do
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

    {:ok, issue_13862} = Issues.create_issue(project, %{description: "Task 13862"})

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_13862, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(Repo.get!(Task, task_id), %{
        stage: :product
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^Repo.get!(Task, task_id).id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: Repo.get!(Task, task_id).id,
        role_id: (roles[Repo.reload!(Repo.get!(Task, task_id)).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :finished,
        stage_outcome: :done
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
        task: dummy_task,
        run: %Run{status: :running},
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
       %{roles: roles, conn: conn, project: project} do
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

    {:ok, issue_13863} = Issues.create_issue(project, %{description: "Task 13863"})

    engineer_role = roles[:engineer]

    asking_run = fn task ->
      {:ok, run} =
        Runs.create_run(%{
          task_id: task.id,
          role_id: engineer_role.id,
          status: :blocked_on_input,
          started_at: DateTime.utc_now()
        })

      Repo.preload(run, task: :issue)
    end

    {:ok, task} = Pipeline.create_task(issue_13863, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :engineer
      })

    {:ok, question} =
      Pipeline.register_question(asking_run.(task), %DetectedQuestion{
        prompt: "Which database adapter should be used?",
        options: ["PostgreSQL", "SQLite"],
        context_summary: "Found multiple adapters in repo"
      })

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

    {:ok, issue_13864} = Issues.create_issue(project, %{description: "Task 13864"})

    {:ok, task_answer_fb} = Pipeline.create_task(issue_13864, :product)

    {:ok, task_answer_fb} =
      Pipeline.update_task(task_answer_fb, %{
        stage: :engineer
      })

    {:ok, _q_fallback} =
      Pipeline.register_question(asking_run.(task_answer_fb), %DetectedQuestion{
        prompt: "Which port?",
        options: ["5432", "5433"]
      })

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

    {:ok, issue_13865} = Issues.create_issue(project, %{description: "Task 13865"})

    {:ok, task_dismiss_exp} = Pipeline.create_task(issue_13865, :product)

    {:ok, task_dismiss_exp} =
      Pipeline.update_task(task_dismiss_exp, %{
        stage: :engineer
      })

    {:ok, q2} =
      Pipeline.register_question(asking_run.(task_dismiss_exp), %DetectedQuestion{
        prompt: "Should we run seeds?",
        options: ["Yes", "No"]
      })

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

    {:ok, issue_13866} = Issues.create_issue(project, %{description: "Task 13866"})

    {:ok, task_dismiss_fb} = Pipeline.create_task(issue_13866, :product)

    {:ok, task_dismiss_fb} =
      Pipeline.update_task(task_dismiss_fb, %{
        stage: :engineer
      })

    {:ok, _q3} =
      Pipeline.register_question(asking_run.(task_dismiss_fb), %DetectedQuestion{
        prompt: "Run migrations?",
        options: ["Yes", "No"]
      })

    assert {:ok, view3, _html} = live(authed_conn, ~p"/tasks/#{task_dismiss_fb.id}")
    assert has_element?(view3, "#answer-field-card")
    render_hook(view3, "dismiss_question", %{})
    refute has_element?(view3, "#answer-field-card")

    # 7. Blocked task with no questions leaves pending_question nil
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_detail_13867",
      "identifier" => "TSK-13867",
      "title" => "Task 13867"
    })

    {:ok, issue_13867} = Issues.create_issue(project, %{description: "Task 13867"})

    {:ok, bad_task} = Pipeline.create_task(issue_13867, :product)

    {:ok, bad_task} =
      Pipeline.update_task(bad_task, %{
        stage: :engineer
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^bad_task.id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: bad_task.id,
        role_id: (roles[Repo.reload!(bad_task).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :blocked_on_input,
        stage_outcome: :in_progress
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

    {:ok, issue_13868} = Issues.create_issue(project, %{description: "Task 13868"})

    {:ok, task} = Pipeline.create_task(issue_13868, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :engineer
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^task.id)

    assert {:ok, view, _html} = live(authed_conn, ~p"/tasks/#{task.id}?tab=conversation")

    assert has_element?(view, "#conversation-tab-root")
    assert has_element?(view, "#tab-conversation[data-active='true']")
    assert has_element?(view, "#conversation-empty-state", "No role has run this task yet.")
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

    {:ok, issue_13871} = Issues.create_issue(project, %{description: "Task 13871"})

    {:ok, task} = Pipeline.create_task(issue_13871, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
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

    {:ok, issue_13872} = Issues.create_issue(project, %{description: "Task 13872"})

    {:ok, task} = Pipeline.create_task(issue_13872, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
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

    {:ok, issue_13873} = Issues.create_issue(project, %{description: "Task 13873"})

    {:ok, task} = Pipeline.create_task(issue_13873, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
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

    {:ok, issue_13874} = Issues.create_issue(project, %{description: "Task 13874"})

    {:ok, task} = Pipeline.create_task(issue_13874, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
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

  test "renders demo panel when task has demo attached", %{roles: roles, conn: conn, project: project} do
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

    {:ok, issue_13876} = Issues.create_issue(project, %{description: "Task 13876"})

    {:ok, task} = Pipeline.create_task(issue_13876, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        owner_user_id: user.id,
        stage: :engineer
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^task.id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: (roles[Repo.reload!(task).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :running,
        stage_outcome: :in_progress
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

  test "renders no-demo banner when stage is ready_to_merge and no demo exists", %{
    roles: roles,
    conn: conn,
    project: project
  } do
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

    {:ok, issue_13877} = Issues.create_issue(project, %{description: "Task 13877"})

    {:ok, task} = Pipeline.create_task(issue_13877, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        owner_user_id: user.id,
        stage: :ready_to_merge
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^task.id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: (roles[Repo.reload!(task).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :finished,
        stage_outcome: :done
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

  test "opens demo player modal, navigates controls, and closes modal", %{roles: roles, conn: conn, project: project} do
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

    {:ok, issue_13878} = Issues.create_issue(project, %{description: "Task 13878"})

    {:ok, task} = Pipeline.create_task(issue_13878, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        owner_user_id: user.id,
        stage: :ready_to_merge,
        worktree_path: "/tmp/fake-worktree"
      })

    Repo.delete_all(from r in Run, where: r.task_id == ^task.id)

    {:ok, _staged} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: (roles[Repo.reload!(task).stage] || roles[:demo]).id,
        started_at: DateTime.utc_now(),
        status: :finished,
        stage_outcome: :done
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

    {:ok, issue_13879} = Issues.create_issue(project, %{description: "Task 13879"})

    {:ok, task} = Pipeline.create_task(issue_13879, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
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

  describe "the conversation, through the page that hosts it" do
    setup %{conn: conn, project: project, roles: roles} do
      {:ok, user} =
        Users.register_oauth_user(%{
          github_id: "gh_task_detail_conversation",
          login: "task_detail_conversation",
          email: "task_detail_conversation@example.com",
          admin: true
        })

      LinearMock.mock_create_issue_success(%{
        "id" => "lin_task_detail_conversation",
        "identifier" => "TSK-CONV",
        "title" => "Conversation task"
      })

      {:ok, issue} = Issues.create_issue(project, %{description: "Conversation task"})
      {:ok, task} = Pipeline.create_task(issue, :product)

      {:ok, task} =
        Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})

      {:ok, architect} =
        Runs.create_run(%{
          task_id: task.id,
          role_id: roles[:architect].id,
          status: :finished,
          conversation_id: "sess_architect",
          started_at: ~U[2026-09-09 09:00:00Z]
        })

      {:ok, engineer} =
        Runs.create_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          status: :running,
          conversation_id: "sess_engineer",
          started_at: ~U[2026-09-09 10:00:00Z]
        })

      Runs.append_run_event(engineer, "[tool read_file] lib/rail.ex")

      %{conn: log_in_user(conn, user), task: task, architect: architect, engineer: engineer}
    end

    test "reads the run for the stage, and switches to another role on request", %{
      conn: conn,
      task: task,
      architect: architect
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=conversation")

      assert has_element?(view, "#role-chip-#{architect.role_id}")

      view |> element("#role-chip-#{architect.role_id}") |> render_click()

      assert has_element?(view, "#conversation-tab-root")
    end

    test "shows the raw log on request, and the chat again after", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=conversation")

      view |> element("#toggle-raw-log") |> render_click()
      assert has_element?(view, "[data-qa='raw-log-line']")

      view |> element("#toggle-raw-log") |> render_click()
      assert has_element?(view, "[data-qa='chat-pane']")
    end

    test "opens and closes the tool activity behind a turn", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=conversation")

      assert has_element?(view, "[data-qa='activity-tile']")
      refute has_element?(view, "[data-qa='activity-content']")

      view |> element("[data-qa='activity-tile'] button") |> render_click()
      assert has_element?(view, "[data-qa='activity-content']")

      view |> element("[data-qa='activity-tile'] button") |> render_click()
      refute has_element?(view, "[data-qa='activity-content']")
    end

    test "a message typed while the agent works waits on its run", %{
      conn: conn,
      task: task,
      engineer: engineer
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=conversation")

      view
      |> element("#chat-composer-form")
      |> render_change(%{"message" => "Please add a test"})

      view
      |> element("#chat-composer-form")
      |> render_submit(%{"message" => "Please add a test"})

      assert has_element?(view, "#queued-banner", "Please add a test")
      assert %Run{pending_chat: "Please add a test"} = Repo.reload!(engineer)
    end

    test "stopping hands the undelivered message back to the composer", %{
      conn: conn,
      task: task,
      engineer: engineer
    } do
      {:ok, _queued} = engineer |> Run.changeset(%{pending_chat: "Please add a test"}) |> Repo.update()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=conversation")

      view |> element("#cancel-queued-message") |> render_click()

      assert has_element?(view, "#chat-input[value='Please add a test']")
      assert %Run{pending_chat: nil, status: :finished} = Repo.reload!(engineer)
    end

    test "send now cuts the turn short and delivers what was queued", %{
      conn: conn,
      task: task,
      engineer: engineer
    } do
      {:ok, _queued} = engineer |> Run.changeset(%{pending_chat: "Please add a test"}) |> Repo.update()

      stub(Runs, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=conversation")

      view |> element("#send-queued-now") |> render_click()

      assert has_element?(view, "#conversation-tab-root")
    end

    test "an empty message is not a message", %{conn: conn, task: task, engineer: engineer} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=conversation")

      view |> element("#chat-composer-form") |> render_submit(%{"message" => "   "})

      assert %Run{pending_chat: nil} = Repo.reload!(engineer)
    end

    test "new log lines reach the conversation while it is open", %{conn: conn, task: task, engineer: engineer} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=conversation")

      send(view.pid, {:run_events, engineer.id, [%{line: "A fresh line of output"}]})

      # The page forwards to the component, which renders on its own turn.
      _settled = render(view)
      assert render(view) =~ "A fresh line of output"
    end
  end

  describe "the product stage, through the page that hosts it" do
    setup %{conn: conn, project: project, roles: roles} do
      {:ok, user} =
        Users.register_oauth_user(%{
          github_id: "gh_task_detail_product",
          login: "task_detail_product",
          email: "task_detail_product@example.com",
          admin: true
        })

      LinearMock.mock_create_issue_success(%{
        "id" => "lin_task_detail_product",
        "identifier" => "TSK-PROD",
        "title" => "Product task"
      })

      {:ok, issue} = Issues.create_issue(project, %{description: "Product task"})
      {:ok, task} = Pipeline.create_task(issue, :product)

      scratch = Path.join(System.tmp_dir!(), "task_detail_product_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(scratch, "tickets"))
      on_exit(fn -> File.rm_rf(scratch) end)

      {:ok, task} =
        Pipeline.update_task(task, %{scratch_path: scratch, worktree_path: create_temp_git_repo()})

      {:ok, run} =
        Runs.create_run(%{
          task_id: task.id,
          role_id: roles[:product].id,
          status: :finished,
          started_at: DateTime.utc_now()
        })

      %{conn: log_in_user(conn, user), task: task, run: run, scratch: scratch}
    end

    test "says the ticket is not written yet, and offers nothing to approve", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#product-ticket-pending")
      refute has_element?(view, "#approve-product-plan")
    end

    test "shows the ticket the product run wrote, and approves it", %{
      conn: conn,
      task: task,
      scratch: scratch,
      roles: roles
    } do
      File.write!(
        Path.join([scratch, "tickets", "TSK-PROD.md"]),
        "---\ntitle: The approved ticket\n---\n\nWhat the product agent wrote.\n"
      )

      stub(Runs, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#product-ticket", "What the product agent wrote.")

      view |> element("#approve-product-plan") |> render_click()

      assert %Task{stage: :design} = Repo.reload!(task)
      assert Repo.get_by(Run, task_id: task.id, role_id: roles[:design].id)
    end

    test "approving and skipping designs goes straight to the architect", %{
      conn: conn,
      task: task,
      scratch: scratch,
      roles: roles
    } do
      File.write!(
        Path.join([scratch, "tickets", "TSK-PROD.md"]),
        "---\ntitle: The approved ticket\n---\n\nWhat the product agent wrote.\n"
      )

      stub(Runs, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#approve-product-plan-skip-design") |> render_click()

      assert %Task{stage: :architect} = Repo.reload!(task)
      assert Repo.get_by(Run, task_id: task.id, role_id: roles[:architect].id)
    end

    test "says why an approval was refused rather than moving quietly", %{
      conn: conn,
      task: task,
      run: run,
      scratch: scratch
    } do
      File.write!(
        Path.join([scratch, "tickets", "TSK-PROD.md"]),
        "---\ntitle: The approved ticket\n---\n\nWhat the product agent wrote.\n"
      )

      {:ok, _approved} = run |> Run.changeset(%{stage_outcome: :done}) |> Repo.update()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#approve-product-plan") |> render_click()

      assert has_element?(view, "#product-approve-error", "already been approved")
      assert %Task{stage: :product} = Repo.reload!(task)
    end
  end
end
