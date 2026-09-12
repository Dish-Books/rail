defmodule RailWeb.OverviewLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Scope
  alias Rail.Users
  alias RailTest.Mocks.Linear, as: LinearMock
  alias RailWeb.Components.ApprovalCard
  alias RailWeb.Components.ProjectBadge
  alias RailWeb.Components.QuestionCard

  test "redirects unauthenticated user to /auth/github", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/github"}}} = live(conn, ~p"/")
  end

  test "renders Overview view and navigation rail with active Overview destination", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_live_1",
        login: "overview_live_user_1",
        email: "overview_live_user_1@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/")

    assert has_element?(view, "#overview-view")
    assert has_element?(view, "#overview-title", "Overview")
    assert has_element?(view, "#running-agent-count-pill", "0 agents running")

    # Nav rail checks
    assert has_element?(view, "#navigation-rail")
    assert has_element?(view, "#nav-overview[data-active='true']")
    assert has_element?(view, "#nav-issues[data-active='false']")
    assert has_element?(view, "#nav-settings[data-active='false']")

    # Top app bar checks
    assert has_element?(view, "#top-app-bar")
    assert has_element?(view, "#section-title", "Overview")
    assert has_element?(view, "#project-switcher-button")
    assert has_element?(view, "#global-capture-idea-button")
    assert has_element?(view, "#theme-toggle-button")
  end

  test "project switcher displays active projects count and switches projects via handle_params", %{
    conn: conn
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_live_2",
        login: "overview_live_user_2",
        email: "overview_live_user_2@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: p1_id, name: p1_name}} =
             Projects.create_project(scope, %{
               name: "Project One",
               github_repo: "example/p1",
               github_installation_id: 111,
               linear_team_id: "t1",
               linear_team_key: "P1",
               default_branch: "main",
               clone_path: "/tmp/p1",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    assert {:ok, %Project{id: p2_id, name: p2_name}} =
             Projects.create_project(scope, %{
               name: "Project Two",
               github_repo: "example/p2",
               github_installation_id: 222,
               linear_team_id: "t2",
               linear_team_key: "P2",
               default_branch: "main",
               clone_path: "/tmp/p2",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    assert {:ok, view, _html} = live(authed_conn, ~p"/")

    # Initial state: All projects
    assert has_element?(view, "#selected-project-name", "All projects")
    assert has_element?(view, "#active-project-count", "2")
    refute has_element?(view, "#project-switcher-dialog")

    # Open project switcher
    view |> element("#project-switcher-button") |> render_click()
    assert has_element?(view, "#project-switcher-dialog")
    assert has_element?(view, "#project-option-#{p1_id}", p1_name)
    assert has_element?(view, "#project-option-#{p2_id}", p2_name)

    # Select Project One
    view |> element("#project-option-#{p1_id}") |> render_click()

    # URL updated to ?project=p1_id via push_patch and handle_params
    assert_patched(view, ~p"/?project=#{p1_id}")
    refute has_element?(view, "#project-switcher-dialog")
    assert has_element?(view, "#selected-project-name", p1_name)

    # Switch back to All projects
    view |> element("#project-switcher-button") |> render_click()
    view |> element("#project-option-all") |> render_click()

    assert_patched(view, ~p"/")
    assert has_element?(view, "#selected-project-name", "All projects")
  end

  test "mount with ?project=<id> in query params sets current_project_id", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_live_3",
        login: "overview_live_user_3",
        email: "overview_live_user_3@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Overview Live Workspace",
        external_id: "lin_ws_overview_live",
        token: "lin_api_token_overview_live",
        webhook_secret: "whsec_overview_live"
      })

    assert {:ok, %Project{id: project_id, name: project_name}} =
             Projects.create_project(scope, %{
               name: "Preset Project",
               github_repo: "example/preset",
               github_installation_id: 333,
               linear_team_id: "tp",
               linear_team_key: "PRE",
               default_branch: "main",
               clone_path: "/tmp/preset",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    assert {:ok, view, _html} = live(authed_conn, ~p"/?project=#{project_id}")
    assert has_element?(view, "#selected-project-name", project_name)
  end

  test "toggles navigation rail expanded and collapsed state", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_live_4",
        login: "overview_live_user_4",
        email: "overview_live_user_4@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/")
    assert has_element?(view, "#brand-name", "Rail")

    # Collapse rail
    view |> element("#rail-toggle") |> render_click()
    refute has_element?(view, "#brand-name")

    # Expand rail
    view |> element("#rail-toggle") |> render_click()
    assert has_element?(view, "#brand-name", "Rail")
  end

  # The Theme hook flips <html data-theme> itself and reports the result back, so the
  # server only ever reacts to "theme_changed".
  test "follows the theme the client reports", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_live_5",
        login: "overview_live_user_5",
        email: "overview_live_user_5@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/")
    assert has_element?(view, "#theme-toggle-button[phx-hook='Theme']")
    assert has_element?(view, "#theme-toggle-button[title='Switch to Light mode']")

    render_hook(view, "theme_changed", %{"theme" => "light"})
    assert has_element?(view, "#theme-toggle-button[title='Switch to Dark mode']")

    render_hook(view, "theme_changed", %{"theme" => "dark"})
    assert has_element?(view, "#theme-toggle-button[title='Switch to Light mode']")
  end

  test "opens and closes new issue modal", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_live_6",
        login: "overview_live_user_6",
        email: "overview_live_user_6@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/")
    refute has_element?(view, "#new-issue-modal")

    # Open modal
    view |> element("#global-capture-idea-button") |> render_click()
    assert has_element?(view, "#new-issue-modal")
    assert has_element?(view, "#modal-headline", "New Issue")

    # Close modal
    view |> element("#close-new-issue-button") |> render_click()
    refute has_element?(view, "#new-issue-modal")
  end

  test "close_project_switcher event closes open dialog", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_live_7",
        login: "overview_live_user_7",
        email: "overview_live_user_7@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/")
    view |> element("#project-switcher-button") |> render_click()
    assert has_element?(view, "#project-switcher-dialog")

    render_hook(view, "close_project_switcher", %{})
    refute has_element?(view, "#project-switcher-dialog")
  end

  test "renders attention badge when tasks require attention and reacts to pipeline_changed", %{
    conn: conn
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_live_8",
        login: "overview_live_user_8",
        email: "overview_live_user_8@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Overview Live Workspace",
        external_id: "lin_ws_overview_live",
        token: "lin_api_token_overview_live",
        webhook_secret: "whsec_overview_live"
      })

    assert {:ok, %Project{id: _project_id} = project} =
             Projects.create_project(scope, %{
               name: "Attention App",
               github_repo: "example/att",
               github_installation_id: 444,
               linear_team_id: "t_att",
               linear_team_key: "ATT",
               default_branch: "main",
               clone_path: "/tmp/att",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_overview_live_13416",
      "identifier" => "TSK-13416",
      "title" => "Task 13416"
    })

    {:ok, issue_13416} = Issues.capture_issue(system_scope(), project, "Task 13416")

    {:ok, task} = Pipeline.create_task(issue_13416, :product)

    {:ok, _task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :failed
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/")
    assert has_element?(view, "#attention-badge")

    # Send PubSub message pipeline_changed
    send(view.pid, {:pipeline_changed, %{event: :task_created}})
    assert has_element?(view, "#attention-badge")
  end

  test "renders singular running agent label when running_count is 1", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_live_9",
        login: "overview_live_user_9",
        email: "overview_live_user_9@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Overview Live Workspace",
        external_id: "lin_ws_overview_live",
        token: "lin_api_token_overview_live",
        webhook_secret: "whsec_overview_live"
      })

    assert {:ok, %Project{id: _project_id} = project} =
             Projects.create_project(scope, %{
               name: "Running Project",
               github_repo: "example/running",
               github_installation_id: 555,
               linear_team_id: "t_run",
               linear_team_key: "RUN",
               default_branch: "main",
               clone_path: "/tmp/running",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_overview_live_13417",
      "identifier" => "TSK-13417",
      "title" => "Task 13417"
    })

    {:ok, issue_13417} = Issues.capture_issue(system_scope(), project, "Task 13417")

    {:ok, task} = Pipeline.create_task(issue_13417, :product)

    {:ok, _task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/")
    assert has_element?(view, "#running-agent-count-pill", "1 agent running")

    # Verify handle_info updates running count when new task runs
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_overview_live_13418",
      "identifier" => "TSK-13418",
      "title" => "Task 13418"
    })

    {:ok, issue_13418} = Issues.capture_issue(system_scope(), project, "Task 13418")

    {:ok, task2} = Pipeline.create_task(issue_13418, :product)

    {:ok, _task2} =
      Pipeline.update_task(system_scope(), task2.id, %{
        stage: :engineer,
        stage_state: :running
      })

    send(view.pid, :pipeline_changed)
    assert has_element?(view, "#running-agent-count-pill", "2 agents running")

    # Send unknown info message to test fallback handle_info
    send(view.pid, :unhandled_info_message)
    assert has_element?(view, "#running-agent-count-pill", "2 agents running")
  end

  test "running count with project filter updates on a pipeline_changed broadcast", %{conn: conn} do
    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Overview Live Workspace",
        external_id: "lin_ws_overview_live",
        token: "lin_api_token_overview_live",
        webhook_secret: "whsec_overview_live"
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_live_10",
        login: "overview_live_user_10",
        email: "overview_live_user_10@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: p1_id} = p1} =
             Projects.create_project(scope, %{
               name: "Project P1",
               github_repo: "example/p1-run",
               github_installation_id: 881,
               linear_team_id: "t_p1",
               linear_team_key: "P1R",
               default_branch: "main",
               clone_path: "/tmp/p1-run",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    assert {:ok, %Project{id: _p2_id} = p2} =
             Projects.create_project(scope, %{
               name: "Project P2",
               github_repo: "example/p2-run",
               github_installation_id: 882,
               linear_team_id: "t_p2",
               linear_team_key: "P2R",
               default_branch: "main",
               clone_path: "/tmp/p2-run",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_overview_live_13419",
      "identifier" => "TSK-13419",
      "title" => "Task 13419"
    })

    {:ok, issue_13419} = Issues.capture_issue(system_scope(), p1, "Task 13419")

    {:ok, task1} = Pipeline.create_task(issue_13419, :product)

    {:ok, _task1} =
      Pipeline.update_task(system_scope(), task1.id, %{
        stage: :engineer,
        stage_state: :running
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_overview_live_13420",
      "identifier" => "TSK-13420",
      "title" => "Task 13420"
    })

    {:ok, issue_13420} = Issues.capture_issue(system_scope(), p2, "Task 13420")

    {:ok, task2} = Pipeline.create_task(issue_13420, :product)

    {:ok, _task2} =
      Pipeline.update_task(system_scope(), task2.id, %{
        stage: :engineer,
        stage_state: :running
      })

    # When viewing P1 only, running count should be 1
    assert {:ok, view, _html} = live(authed_conn, ~p"/?project=#{p1_id}")
    assert has_element?(view, "#running-agent-count-pill", "1 agent running")

    send(view.pid, {:pipeline_changed, %{task_id: "tsk_whatever", event: :dispatched}})
    assert has_element?(view, "#running-agent-count-pill", "1 agent running")
  end

  test "renders empty state 'All clear' when no tasks wait and no agents run, hiding merged tasks", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_live_11",
        login: "overview_live_user_11",
        email: "overview_live_user_11@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Overview Live Workspace",
        external_id: "lin_ws_overview_live",
        token: "lin_api_token_overview_live",
        webhook_secret: "whsec_overview_live"
      })

    assert {:ok, %Project{id: _project_id} = project} =
             Projects.create_project(scope, %{
               name: "Empty App",
               github_repo: "example/empty",
               github_installation_id: 991,
               linear_team_id: "t_empty",
               linear_team_key: "EMP",
               default_branch: "main",
               clone_path: "/tmp/empty",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_overview_live_13421",
      "identifier" => "TSK-13421",
      "title" => "Already Merged Task"
    })

    {:ok, issue_13421} = Issues.capture_issue(system_scope(), project, "Already Merged Task")

    {:ok, %Task{id: merged_id}} = Pipeline.create_task(issue_13421, :product)
    merged_title = issue_13421.title

    {:ok, %Task{id: merged_id}} =
      Pipeline.update_task(system_scope(), merged_id, %{
        stage: :merged,
        stage_state: :queued
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/")

    assert has_element?(view, "#overview-empty-state")
    assert has_element?(view, "#empty-state-title", "All clear")
    assert has_element?(view, "#empty-state-subtitle", "Nothing is waiting on you. Bring an issue local to start a task.")
    refute has_element?(view, "#waiting-header")
    refute has_element?(view, "#with-agent-section")
    refute has_element?(view, "#approval-card-task-#{merged_id}")
    refute has_element?(view, "#with-agent-card-#{merged_id}")
    assert render(view) =~ "All clear"
    refute render(view) =~ merged_title
  end

  test "renders dispatch banner when RAIL_NO_DISPATCH=1", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_live_12",
        login: "overview_live_user_12",
        email: "overview_live_user_12@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    System.put_env("RAIL_NO_DISPATCH", "1")
    on_exit(fn -> System.delete_env("RAIL_NO_DISPATCH") end)

    assert {:ok, view, _html} = live(authed_conn, ~p"/")
    assert has_element?(view, "#dispatch-disabled-banner")
    assert render(view) =~ "RAIL_NO_DISPATCH=1 is set"
  end

  test "renders question card with options, handles answer clicks, text submission, and dismissal", %{
    conn: conn
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_live_13",
        login: "overview_live_user_13",
        email: "overview_live_user_13@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Overview Live Workspace",
        external_id: "lin_ws_overview_live",
        token: "lin_api_token_overview_live",
        webhook_secret: "whsec_overview_live"
      })

    assert {:ok, %Project{id: project_id} = project} =
             Projects.create_project(scope, %{
               name: "Question App",
               github_repo: "example/qapp",
               github_installation_id: 992,
               linear_team_id: "t_q",
               linear_team_key: "QST",
               default_branch: "main",
               clone_path: "/tmp/qapp",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, %Role{id: role_id}} =
      Roles.create_role(system_scope(), project_id, %{
        backend_id: backend.id,
        name: "Backend Engineer",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 13401.",
        stage: :engineer
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_overview_live_13422",
      "identifier" => "TSK-13422",
      "title" => "Build Graph API"
    })

    {:ok, issue_13422} = Issues.capture_issue(system_scope(), project, "Build Graph API")

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_13422, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), task_id, %{
        stage: :engineer,
        stage_state: :blocked
      })

    {:ok, _run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :blocked_on_input,
        started_at: DateTime.utc_now()
      })

    {:ok, %Question{id: _q1_id, prompt: q1_prompt}} =
      Pipeline.register_question(task_id, %{
        prompt: "Which database adapter?",
        role_id: role_id,
        options: ["Postgres", "SQLite"],
        context_summary: "We need persistent storage for logs"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_overview_orphan",
      "identifier" => "OVL-ORPHAN",
      "title" => "Orphan question task"
    })

    {:ok, orphan_issue} = Issues.capture_issue(system_scope(), project, "Orphan question task")
    {:ok, %Task{id: orphan_task_id} = orphan_task} = Pipeline.create_task(orphan_issue, :product)

    {:ok, %Question{prompt: q_orphan_prompt}} =
      Pipeline.register_question(orphan_task, %{
        prompt: "Orphan clarification prompt?",
        options: ["Option Alpha", "Option Beta"]
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/")

    assert has_element?(view, "#question-card-task-#{task_id}")
    assert has_element?(view, "#question-card-task-#{orphan_task_id}")
    assert has_element?(view, "#waiting-header", "WAITING ON YOU · 2")
    assert render(view) =~ q1_prompt
    assert render(view) =~ "We need persistent storage for logs"
    assert render(view) =~ q_orphan_prompt

    # Click option button to answer q1
    view
    |> element("#question-option-task-#{task_id}-0")
    |> render_click()

    refute has_element?(view, "#question-card-task-#{task_id}")
    assert has_element?(view, "#question-card-task-#{orphan_task_id}")

    # Empty answer text submission guard
    view
    |> form("#answer-form-task-#{orphan_task_id}", %{"answer" => "   "})
    |> render_submit()

    assert has_element?(view, "#question-card-task-#{orphan_task_id}")

    # Dismiss question
    view
    |> element("#dismiss-question-task-#{orphan_task_id}")
    |> render_click()

    refute has_element?(view, "#question-card-task-#{orphan_task_id}")
  end

  test "submits question answer text via form", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_live_14",
        login: "overview_live_user_14",
        email: "overview_live_user_14@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Overview Live Workspace",
        external_id: "lin_ws_overview_live",
        token: "lin_api_token_overview_live",
        webhook_secret: "whsec_overview_live"
      })

    assert {:ok, %Project{id: project_id} = project} =
             Projects.create_project(scope, %{
               name: "Form Q App",
               github_repo: "example/formq",
               github_installation_id: 993,
               linear_team_id: "t_fq",
               linear_team_key: "FQA",
               default_branch: "main",
               clone_path: "/tmp/formq",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, %Role{id: role_id}} =
      Roles.create_role(system_scope(), project_id, %{
        backend_id: backend.id,
        name: "Form Engineer",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 13402.",
        stage: :engineer
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_overview_live_13423",
      "identifier" => "TSK-13423",
      "title" => "Freeform Task"
    })

    {:ok, issue_13423} = Issues.capture_issue(system_scope(), project, "Freeform Task")

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_13423, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: task_id}.id, %{
        stage: :engineer,
        stage_state: :blocked
      })

    {:ok, _run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :blocked_on_input,
        started_at: DateTime.utc_now()
      })

    {:ok, %Question{id: q_id}} =
      Pipeline.register_question(task_id, %{
        prompt: "What port number?",
        role_id: role_id,
        options: []
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/")
    assert has_element?(view, "#question-card-task-#{task_id}")

    view
    |> form("#answer-form-task-#{task_id}", %{"question_id" => q_id, "answer" => "4000"})
    |> render_submit()

    refute has_element?(view, "#question-card-task-#{task_id}")
  end

  test "renders approval cards for stages and handles send back comments flow", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_live_15",
        login: "overview_live_user_15",
        email: "overview_live_user_15@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Overview Live Workspace",
        external_id: "lin_ws_overview_live",
        token: "lin_api_token_overview_live",
        webhook_secret: "whsec_overview_live"
      })

    assert {:ok, %Project{id: project_id} = project} =
             Projects.create_project(scope, %{
               name: "Approval App",
               github_repo: "example/approval",
               github_installation_id: 994,
               linear_team_id: "t_appr",
               linear_team_key: "APR",
               default_branch: "main",
               clone_path: "/tmp/approval",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, _role_arch} =
      Roles.create_role(system_scope(), project_id, %{
        backend_id: backend.id,
        name: "Architect",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 13403.",
        stage: :architect
      })

    {:ok, _role_prod} =
      Roles.create_role(system_scope(), project_id, %{
        backend_id: backend.id,
        name: "Product",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 13404.",
        stage: :product
      })

    {:ok, _role_eng} =
      Roles.create_role(system_scope(), project_id, %{
        backend_id: backend.id,
        name: "Engineer",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 13405.",
        stage: :engineer
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_overview_live_13424",
      "identifier" => "TSK-13424",
      "title" => "Architect Approval Task"
    })

    {:ok, issue_13424} = Issues.capture_issue(system_scope(), project, "Architect Approval Task")

    {:ok, %Task{id: arch_id}} = Pipeline.create_task(issue_13424, :product)
    arch_title = issue_13424.title

    {:ok, %Task{id: arch_id}} =
      Pipeline.update_task(system_scope(), arch_id, %{
        stage: :architect,
        stage_state: :awaiting_approval,
        error: "Architect notes here"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_overview_live_13425",
      "identifier" => "TSK-13425",
      "title" => "Product Approval Task"
    })

    {:ok, issue_13425} = Issues.capture_issue(system_scope(), project, "Product Approval Task")

    {:ok, %Task{id: prod_id}} = Pipeline.create_task(issue_13425, :product)
    prod_title = issue_13425.title

    {:ok, %Task{id: prod_id}} =
      Pipeline.update_task(system_scope(), prod_id, %{
        stage: :product,
        stage_state: :awaiting_approval
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_overview_live_13426",
      "identifier" => "TSK-13426",
      "title" => "Engineer Approval Task"
    })

    {:ok, issue_13426} = Issues.capture_issue(system_scope(), project, "Engineer Approval Task")

    {:ok, %Task{id: eng_id}} = Pipeline.create_task(issue_13426, :product)
    eng_title = issue_13426.title

    {:ok, %Task{id: eng_id}} =
      Pipeline.update_task(system_scope(), eng_id, %{
        stage: :engineer,
        stage_state: :awaiting_approval
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/")

    # Architect card checks
    assert has_element?(view, "#approval-card-task-#{arch_id}")
    assert has_element?(view, "#approval-title-link-task-#{arch_id}", arch_title)
    assert has_element?(view, "#approval-primary-action-task-#{arch_id}", "Open plan")
    assert has_element?(view, "#approval-detail-task-#{arch_id}", "Architect notes here")

    # Product card checks
    assert has_element?(view, "#approval-card-task-#{prod_id}")
    assert has_element?(view, "#approval-title-link-task-#{prod_id}", prod_title)
    assert has_element?(view, "#approval-primary-action-task-#{prod_id}", "Open ticket")

    # Engineer card checks
    assert has_element?(view, "#approval-card-task-#{eng_id}")
    assert has_element?(view, "#approval-title-link-task-#{eng_id}", eng_title)
    assert has_element?(view, "#approval-primary-action-task-#{eng_id}", "Open diff")

    # Open send back modal on Architect task
    view |> element("#send-back-button-task-#{arch_id}") |> render_click()
    assert has_element?(view, "#send-back-modal")
    assert has_element?(view, "#send-back-modal-title", "Send back with comments")

    # Change event on form
    render_change(view, "send_back_change", %{})

    # Close send back modal
    view |> element("#close-send-back-button") |> render_click()
    refute has_element?(view, "#send-back-modal")

    # Re-open modal and submit comments
    view |> element("#send-back-button-task-#{arch_id}") |> render_click()
    assert has_element?(view, "#send-back-modal")

    view
    |> form("#send-back-form", %{"task_id" => arch_id, "comment" => "Need updated diagrams"})
    |> render_submit()

    refute has_element?(view, "#send-back-modal")

    # Open send back with invalid task ID does not crash
    render_hook(view, "open_send_back", %{"task_id" => "tsk_invalid_id"})
    refute has_element?(view, "#send-back-modal")
  end

  test "renders compact waiting strip for failed, ready to merge, and conflict tasks, and handles merge and rebase modals",
       %{
         conn: conn
       } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_live_16",
        login: "overview_live_user_16",
        email: "overview_live_user_16@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Overview Live Workspace",
        external_id: "lin_ws_overview_live",
        token: "lin_api_token_overview_live",
        webhook_secret: "whsec_overview_live"
      })

    assert {:ok, %Project{id: _project_id} = project} =
             Projects.create_project(scope, %{
               name: "Compact App",
               github_repo: "example/compact",
               github_installation_id: 995,
               linear_team_id: "t_c",
               linear_team_key: "CMP",
               default_branch: "main",
               clone_path: "/tmp/compact",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_overview_live_13427",
      "identifier" => "TSK-13427",
      "title" => "Failed Build Task"
    })

    {:ok, issue_13427} = Issues.capture_issue(system_scope(), project, "Failed Build Task")

    {:ok, %Task{id: failed_id}} = Pipeline.create_task(issue_13427, :product)
    failed_title = issue_13427.title

    {:ok, %Task{id: failed_id}} =
      Pipeline.update_task(system_scope(), failed_id, %{
        stage: :engineer,
        stage_state: :failed,
        error: "Compilation error in worker.ex"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_overview_live_13428",
      "identifier" => "TSK-13428",
      "title" => "Ready PR Task"
    })

    {:ok, issue_13428} = Issues.capture_issue(system_scope(), project, "Ready PR Task")

    {:ok, %Task{id: merge_id}} = Pipeline.create_task(issue_13428, :product)
    merge_title = issue_13428.title

    {:ok, %Task{id: merge_id}} =
      Pipeline.update_task(system_scope(), merge_id, %{
        stage: :ready_to_merge,
        stage_state: :queued,
        pr_number: nil
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_overview_live_13429",
      "identifier" => "TSK-13429",
      "title" => "Conflicted Branch Task"
    })

    {:ok, issue_13429} = Issues.capture_issue(system_scope(), project, "Conflicted Branch Task")

    {:ok, %Task{id: conflict_id}} = Pipeline.create_task(issue_13429, :product)
    conflict_title = issue_13429.title

    {:ok, %Task{id: conflict_id}} =
      Pipeline.update_task(system_scope(), conflict_id, %{
        stage: :engineer,
        stage_state: :queued,
        mergeability: :conflicting
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/")

    assert has_element?(view, "[data-qa='compact-waiting-strip']")

    # Failed row checks
    assert has_element?(view, "#compact-row-task-#{failed_id}")
    assert has_element?(view, "#action-open-log-#{failed_id}", "Open log")
    assert render(view) =~ failed_title
    assert render(view) =~ "Compilation error in worker.ex"
    assert render(view) =~ "Failed"

    # Ready to merge row checks
    assert has_element?(view, "#compact-row-task-#{merge_id}")
    assert has_element?(view, "#action-merge-#{merge_id}", "Merge")
    assert render(view) =~ merge_title
    assert render(view) =~ "Ready to merge"

    # Conflicts row checks
    assert has_element?(view, "#compact-row-task-#{conflict_id}")
    assert has_element?(view, "#action-rebase-#{conflict_id}", "Rebase")
    assert render(view) =~ conflict_title
    assert render(view) =~ "Conflicts"

    # Merge modal flow: open -> cancel -> open -> confirm
    view |> element("#action-merge-#{merge_id}") |> render_click()
    assert has_element?(view, "#merge-confirm-modal")
    assert has_element?(view, "#merge-modal-title", "Merge this pull request?")

    view |> element("#cancel-merge-button") |> render_click()
    refute has_element?(view, "#merge-confirm-modal")

    view |> element("#action-merge-#{merge_id}") |> render_click()
    view |> element("#confirm-merge-button") |> render_click()
    refute has_element?(view, "#merge-confirm-modal")

    # Rebase modal flow: open -> cancel -> open -> confirm
    view |> element("#action-rebase-#{conflict_id}") |> render_click()
    assert has_element?(view, "#rebase-confirm-modal")
    assert has_element?(view, "#rebase-modal-title", "Rebase this branch?")

    view |> element("#cancel-rebase-button") |> render_click()
    refute has_element?(view, "#rebase-confirm-modal")

    view |> element("#action-rebase-#{conflict_id}") |> render_click()
    view |> element("#confirm-rebase-button") |> render_click()
    refute has_element?(view, "#rebase-confirm-modal")

    # Invalid ID handlers do not crash
    render_hook(view, "open_merge", %{"task_id" => "tsk_non_existent"})
    refute has_element?(view, "#merge-confirm-modal")

    render_hook(view, "open_rebase", %{"task_id" => "tsk_non_existent"})
    refute has_element?(view, "#rebase-confirm-modal")
  end

  test "renders with-an-agent section with running, queued, rebasing, and blocked tasks sorted by updated_at", %{
    conn: conn
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_live_17",
        login: "overview_live_user_17",
        email: "overview_live_user_17@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Overview Live Workspace",
        external_id: "lin_ws_overview_live",
        token: "lin_api_token_overview_live",
        webhook_secret: "whsec_overview_live"
      })

    assert {:ok, %Project{id: _project_id} = project} =
             Projects.create_project(scope, %{
               name: "Agent App",
               github_repo: "example/agentapp",
               github_installation_id: 996,
               linear_team_id: "t_ag",
               linear_team_key: "AGP",
               default_branch: "main",
               clone_path: "/tmp/agentapp",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_overview_live_13430",
      "identifier" => "TSK-13430",
      "title" => "Queued Design Task"
    })

    {:ok, issue_13430} = Issues.capture_issue(system_scope(), project, "Queued Design Task")

    {:ok, %Task{id: t_queued_id}} = Pipeline.create_task(issue_13430, :product)

    {:ok, %Task{id: t_queued_id}} =
      Pipeline.update_task(system_scope(), %Task{id: t_queued_id}.id, %{
        stage: :design,
        stage_state: :queued
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_overview_live_13431",
      "identifier" => "TSK-13431",
      "title" => "Active Rebasing Task"
    })

    {:ok, issue_13431} = Issues.capture_issue(system_scope(), project, "Active Rebasing Task")

    {:ok, %Task{id: t_rebase_id}} = Pipeline.create_task(issue_13431, :product)

    {:ok, %Task{id: t_rebase_id}} =
      Pipeline.update_task(system_scope(), %Task{id: t_rebase_id}.id, %{
        stage: :engineer,
        stage_state: :running,
        is_rebasing: true
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_overview_live_13432",
      "identifier" => "TSK-13432",
      "title" => "Active Coding Task"
    })

    {:ok, issue_13432} = Issues.capture_issue(system_scope(), project, "Active Coding Task")

    {:ok, %Task{id: t_running_id}} = Pipeline.create_task(issue_13432, :product)

    {:ok, %Task{id: t_running_id}} =
      Pipeline.update_task(system_scope(), %Task{id: t_running_id}.id, %{
        stage: :engineer,
        stage_state: :running
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/")

    assert has_element?(view, "#with-agent-section")
    assert has_element?(view, "#with-agent-header", "WITH AN AGENT · 3 · RECENTLY UPDATED")
    assert has_element?(view, "#with-agent-card-#{t_running_id}")
    assert has_element?(view, "#with-agent-card-#{t_rebase_id}")
    assert has_element?(view, "#with-agent-card-#{t_queued_id}")

    html = render(view)
    assert html =~ "Running"
    assert html =~ "Rebasing"
    assert html =~ "Queued"

    pos_running = html |> :binary.match(t_running_id) |> elem(0)
    pos_rebase = html |> :binary.match(t_rebase_id) |> elem(0)
    pos_queued = html |> :binary.match(t_queued_id) |> elem(0)

    assert pos_running < pos_rebase
    assert pos_rebase < pos_queued
  end

  test "renders role roster across projects and single project filter, showing idle, running, chatting, and waiting states",
       %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_live_18",
        login: "overview_live_user_18",
        email: "overview_live_user_18@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    scope = Scope.for_user(user)

    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Overview Live Workspace",
        external_id: "lin_ws_overview_live",
        token: "lin_api_token_overview_live",
        webhook_secret: "whsec_overview_live"
      })

    assert {:ok, %Project{id: project_id, name: project_name} = project} =
             Projects.create_project(scope, %{
               name: "Roster Project",
               github_repo: "example/roster",
               github_installation_id: 997,
               linear_team_id: "t_rst",
               linear_team_key: "RST",
               default_branch: "main",
               clone_path: "/tmp/roster",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, %Role{id: r_eng_id}} =
      Roles.create_role(system_scope(), project_id, %{
        backend_id: backend.id,
        name: "Software Engineer",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 13406.",
        stage: :engineer,
        icon_name: "pi-code"
      })

    {:ok, %Role{id: r_arch_id}} =
      Roles.create_role(system_scope(), project_id, %{
        backend_id: backend.id,
        name: "System Architect",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 13407.",
        stage: :architect,
        icon_name: "pi-compass-tool"
      })

    {:ok, %Role{id: r_des_id}} =
      Roles.create_role(system_scope(), project_id, %{
        backend_id: backend.id,
        name: "UI Designer",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 13408.",
        stage: :design,
        icon_name: "pi-palette"
      })

    {:ok, %Role{id: r_qa_id}} =
      Roles.create_role(system_scope(), project_id, %{
        backend_id: backend.id,
        name: "QA Specialist",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 13409.",
        stage: :qa,
        icon_name: "pi-flask"
      })

    {:ok, %Role{id: r_demo_id}} =
      Roles.create_role(system_scope(), project_id, %{
        backend_id: backend.id,
        name: "Demo Recorder",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 13410.",
        stage: :demo,
        icon_name: "pi-video-camera"
      })

    {:ok, %Role{id: r_custom_id}} =
      Roles.create_role(system_scope(), project_id, %{
        backend_id: backend.id,
        name: "Custom Bot",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 13411.",
        stage: nil,
        icon_name: "pi-robot"
      })

    {:ok, %Role{id: r_prod_id}} =
      Roles.create_role(system_scope(), project_id, %{
        backend_id: backend.id,
        name: "Product Manager",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 13412.",
        stage: :product,
        icon_name: "pi-clipboard-text"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_overview_live_13415",
      "identifier" => "ENG-101",
      "title" => "Overview Live Issue 13415"
    })

    {:ok, %Issue{id: issue_id, identifier: issue_identifier}} =
      Issues.capture_issue(system_scope(), project, "Overview Live Issue 13415")

    # Running task for Engineer with associated issue
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_overview_live_13433",
      "identifier" => "TSK-13433",
      "title" => "Writing Tests"
    })

    {:ok, issue_13433} = Issues.capture_issue(system_scope(), project, "Writing Tests")

    {:ok, %Task{id: t_eng_id}} = Pipeline.create_task(issue_13433, :product)

    {:ok, %Task{id: t_eng_id}} =
      Pipeline.update_task(system_scope(), %Task{id: t_eng_id}.id, %{
        issue_id: issue_id,
        stage: :engineer,
        stage_state: :running
      })

    # Chatting task for Architect
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_overview_live_13434",
      "identifier" => "TSK-13434",
      "title" => "Brainstorming Architecture"
    })

    {:ok, issue_13434} = Issues.capture_issue(system_scope(), project, "Brainstorming Architecture")

    {:ok, %Task{id: t_arch_id}} = Pipeline.create_task(issue_13434, :product)

    {:ok, %Task{id: t_arch_id}} =
      Pipeline.update_task(system_scope(), %Task{id: t_arch_id}.id, %{
        issue_id: nil,
        stage: :architect,
        stage_state: :running,
        active_chat_role_id: r_arch_id
      })

    # Waiting task for QA
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_overview_live_13435",
      "identifier" => "TSK-13435",
      "title" => "Verify Slice 5.2"
    })

    {:ok, issue_13435} = Issues.capture_issue(system_scope(), project, "Verify Slice 5.2")

    {:ok, %Task{id: t_qa_id}} = Pipeline.create_task(issue_13435, :product)

    {:ok, %Task{id: t_qa_id}} =
      Pipeline.update_task(system_scope(), %Task{id: t_qa_id}.id, %{
        issue_id: nil,
        stage: :qa,
        stage_state: :awaiting_approval
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/")

    assert has_element?(view, "#role-roster")
    assert has_element?(view, "#roster-project-header-#{project_id}", project_name)

    # Software Engineer: running with issue identifier
    assert has_element?(view, "#role-row-#{r_eng_id}")
    assert has_element?(view, "#role-active-link-#{r_eng_id}")
    assert render(view) =~ "#{issue_identifier} · running"

    # System Architect: chatting
    assert has_element?(view, "#role-row-#{r_arch_id}")
    assert has_element?(view, "#role-active-link-#{r_arch_id}")
    assert render(view) =~ "#{t_arch_id} · chatting"

    # QA Specialist: waiting
    assert has_element?(view, "#role-row-#{r_qa_id}")
    assert has_element?(view, "#role-active-link-#{r_qa_id}")
    assert render(view) =~ "Waiting on you · #{t_qa_id}"

    # UI Designer, Demo Recorder, Custom Bot, Product Manager: idle
    assert has_element?(view, "#role-idle-#{r_des_id}")
    assert has_element?(view, "#role-idle-#{r_demo_id}")
    assert has_element?(view, "#role-idle-#{r_custom_id}")
    assert has_element?(view, "#role-idle-#{r_prod_id}")

    # Active role link href
    assert has_element?(view, "#role-active-link-#{r_eng_id}[href='/tasks/#{t_eng_id}']")

    # Filtered by project: project header is hidden
    assert {:ok, filtered_view, _html} = live(authed_conn, ~p"/?project=#{project_id}")
    refute has_element?(filtered_view, "#roster-project-header-#{project_id}")
    assert has_element?(filtered_view, "#role-row-#{r_eng_id}")

    # Filtered with non-existent project id: returns empty
    assert {:ok, missing_view, _html} = live(authed_conn, ~p"/?project=prj_doesnotexist")
    refute has_element?(missing_view, "#roster-project-header-#{project_id}")

    # Trigger noop event
    render_hook(view, "noop", %{})
  end

  test "renders project badge with name when linear_team_key is nil, and renders nothing when project is nil" do
    assert render_component(&ProjectBadge.project_badge/1, project: %{name: "OnlyName", linear_team_key: nil}) =~
             "OnlyName"

    assert render_component(&ProjectBadge.project_badge/1, project: nil) == ""
  end

  test "compact waiting strip renders with issue identifier and fallback label for other kind" do
    task_with_issue = %Task{
      id: "tsk_compact_strip",
      stage: :engineer,
      stage_state: :awaiting_approval,
      issue: %Issue{identifier: "ISS-42", title: "Other Kind Task"}
    }

    row = %{item: %{key: "custom-1"}, kind: :custom, task: task_with_issue, waiting_since: DateTime.utc_now()}
    block = %Rail.Domain.CompactStripBlock{rows: [row]}
    html = render_component(&RailWeb.Components.CompactWaitingStrip.compact_waiting_strip/1, block: block)
    assert html =~ "Waiting"
    assert html =~ "ISS-42"
  end

  test "with agent section renders all state pills, roles, and issue identifiers" do
    now = DateTime.utc_now()

    task_rebase = %Task{
      id: "tsk_reb_1",
      issue: %Issue{title: "Rebase In Agent"},
      is_rebasing: true,
      stage_state: :running,
      stage: :engineer,
      updated_at: now
    }

    task_blocked = %Task{
      id: "tsk_blk_1",
      issue: %Issue{title: "Blocked In Agent"},
      stage_state: :blocked,
      stage: :engineer,
      updated_at: now
    }

    task_approval = %Task{
      id: "tsk_appr_1",
      issue: %Issue{title: "Approval In Agent"},
      stage_state: :awaiting_approval,
      stage: :architect,
      updated_at: now
    }

    task_failed = %Task{
      id: "tsk_fail_1",
      stage_state: :failed,
      stage: :engineer,
      issue: %Issue{identifier: "WAG-100", title: "Failed In Agent"},
      updated_at: now
    }

    task_other = %Task{
      id: "tsk_other_1",
      issue: %Issue{title: "Other In Agent"},
      stage_state: :running,
      stage: nil,
      updated_at: now
    }

    task_role = %{
      id: "tsk_role_map",
      issue: %{title: "Map with role"},
      stage_state: :running,
      stage: nil,
      role: %{name: "Custom Agent Role"},
      project: nil,
      updated_at: now
    }

    rows = [
      %{task: task_rebase},
      %{task: task_blocked},
      %{task: task_approval},
      %{task: task_failed},
      %{task: task_other},
      %{task: task_role}
    ]

    html = render_component(&RailWeb.Components.WithAgentSection.with_agent_section/1, rows: rows)
    assert html =~ "Rebasing"
    assert html =~ "Blocked"
    assert html =~ "Awaiting approval"
    assert html =~ "Failed"
    assert html =~ "Architect"
    assert html =~ "WAG-100"
    assert html =~ "Agent"
    assert html =~ "Custom Agent Role"
  end

  test "approval card renders default diff tab, issue identifier, and fallback role name" do
    task = %Task{
      id: "tsk_test_diff",
      stage: :review,
      stage_state: :awaiting_approval,
      issue: %Issue{identifier: "APP-50", title: "Default Diff Task"},
      inserted_at: DateTime.utc_now(),
      project: nil
    }

    row = %{
      item: %{key: "task:tsk_test_diff"},
      task: task,
      waiting_since: DateTime.utc_now()
    }

    html = render_component(&ApprovalCard.approval_card/1, row: row)
    assert html =~ "Open diff"
    assert html =~ "APP-50"
    assert html =~ "Review"

    task_plain = %Task{
      id: "tsk_plain",
      issue: %Issue{title: "Plain Task"},
      stage: nil,
      stage_state: :awaiting_approval,
      inserted_at: DateTime.utc_now(),
      project: nil
    }

    row_plain = %{item: %{key: "task:tsk_plain"}, task: task_plain, waiting_since: DateTime.utc_now()}
    html_plain = render_component(&ApprovalCard.approval_card/1, row: row_plain)
    assert html_plain =~ "Agent"
  end

  test "question card renders with task issue, role, and fallback role" do
    task_with_issue = %Task{
      id: "tsk_q_issue",
      stage: :architect,
      issue: %Issue{identifier: "QST-88", title: "Question Task"}
    }

    q1 = %Question{
      id: "qst_with_task",
      prompt: "Do we proceed?",
      options: ["Proceed", "Abort"],
      context_summary: "Context",
      task_id: "tsk_q_issue",
      role: %{name: "Lead Architect"}
    }

    row1 = %{
      item: %{key: "question:qst_with_task"},
      question: q1,
      task: task_with_issue,
      waiting_since: DateTime.utc_now()
    }

    html1 = render_component(&QuestionCard.question_card/1, row: row1, submitting: false)
    assert html1 =~ "QST-88"
    assert html1 =~ "Lead Architect"

    q2 = %Question{
      id: "qst_task_ref",
      prompt: "Question with task ref only?",
      options: nil,
      context_summary: nil,
      task_id: "tsk_direct_ref"
    }

    task_stage = %Task{id: "tsk_direct_ref", stage: :engineer}
    row2 = %{item: %{key: "question:qst_task_ref"}, question: q2, task: task_stage, waiting_since: DateTime.utc_now()}
    html2 = render_component(&QuestionCard.question_card/1, row: row2, submitting: false)
    assert html2 =~ "Engineer"

    q3 = %Question{
      id: "qst_plain",
      prompt: "What is your preference?",
      options: nil,
      context_summary: nil,
      task_id: nil
    }

    row3 = %{item: %{key: "question:qst_plain"}, question: q3, task: nil, waiting_since: DateTime.utc_now()}
    html3 = render_component(&QuestionCard.question_card/1, row: row3, submitting: false)
    assert html3 =~ "What is your preference?"
    assert html3 =~ "Agent"
  end
end
