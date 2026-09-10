defmodule RailWeb.OverviewLiveTest do
  use RailWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Dispatcher
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope
  alias RailWeb.Components.ApprovalCard
  alias RailWeb.Components.ProjectBadge
  alias RailWeb.Components.QuestionCard

  test "redirects unauthenticated user to /auth/github", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/github"}}} = live(conn, ~p"/")
  end

  test "renders Overview view and navigation rail with active Overview destination", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/")

    assert has_element?(view, "#overview-view")
    assert has_element?(view, "#overview-title", "Overview")
    assert has_element?(view, "#running-agent-count-pill", "0 agents running")

    # Nav rail checks
    assert has_element?(view, "#navigation-rail")
    assert has_element?(view, "#nav-overview[data-active='true']")
    assert has_element?(view, "#nav-issues[data-active='false']")
    assert has_element?(view, "#nav-cli-accounts[data-active='false']")
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
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: p1_id, name: p1_name}} =
             Projects.create_project(scope, %{
               name: "Project One",
               github_repo: "example/p1",
               github_installation_id: 111,
               linear_team_id: "t1",
               linear_team_key: "P1",
               clone_path: "/tmp/p1",
               active: true
             })

    assert {:ok, %Project{id: p2_id, name: p2_name}} =
             Projects.create_project(scope, %{
               name: "Project Two",
               github_repo: "example/p2",
               github_installation_id: 222,
               linear_team_id: "t2",
               linear_team_key: "P2",
               clone_path: "/tmp/p2",
               active: true
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
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id, name: project_name}} =
             Projects.create_project(scope, %{
               name: "Preset Project",
               github_repo: "example/preset",
               github_installation_id: 333,
               linear_team_id: "tp",
               linear_team_key: "PRE",
               clone_path: "/tmp/preset",
               active: true
             })

    assert {:ok, view, _html} = live(authed_conn, ~p"/?project=#{project_id}")
    assert has_element?(view, "#selected-project-name", project_name)
  end

  test "toggles navigation rail expanded and collapsed state", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/")
    assert has_element?(view, "#brand-name", "Rail")

    # Collapse rail
    view |> element("#rail-toggle") |> render_click()
    refute has_element?(view, "#brand-name")

    # Expand rail
    view |> element("#rail-toggle") |> render_click()
    assert has_element?(view, "#brand-name", "Rail")
  end

  test "toggles theme mode between dark and light", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/")
    assert has_element?(view, "#theme-toggle-button[title='Switch to Light mode']")

    # Toggle to light
    view |> element("#theme-toggle-button") |> render_click()
    assert has_element?(view, "#theme-toggle-button[title='Switch to Dark mode']")

    # Toggle back to dark
    view |> element("#theme-toggle-button") |> render_click()
    assert has_element?(view, "#theme-toggle-button[title='Switch to Light mode']")

    # Client hook event
    render_hook(view, "theme_changed", %{"theme" => "light"})
    assert has_element?(view, "#theme-toggle-button[title='Switch to Dark mode']")
  end

  test "opens and closes new issue modal", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)

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
    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/")
    view |> element("#project-switcher-button") |> render_click()
    assert has_element?(view, "#project-switcher-dialog")

    render_hook(view, "close_project_switcher", %{})
    refute has_element?(view, "#project-switcher-dialog")
  end

  test "renders attention badge when tasks require attention and reacts to pipeline_changed", %{
    conn: conn
  } do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Attention App",
               github_repo: "example/att",
               github_installation_id: 444,
               linear_team_id: "t_att",
               linear_team_key: "ATT",
               clone_path: "/tmp/att",
               active: true
             })

    _task =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :failed
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/")
    assert has_element?(view, "#attention-badge")

    # Send PubSub message pipeline_changed
    send(view.pid, :pipeline_changed)
    assert has_element?(view, "#attention-badge")

    send(view.pid, %{event: "pipeline_changed"})
    assert has_element?(view, "#attention-badge")

    send(view.pid, {:live_sync, %{table: "tasks"}})
    assert has_element?(view, "#attention-badge")
  end

  test "renders singular running agent label when running_count is 1", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Running Project",
               github_repo: "example/running",
               github_installation_id: 555,
               linear_team_id: "t_run",
               linear_team_key: "RUN",
               clone_path: "/tmp/running",
               active: true
             })

    _task =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :running
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/")
    assert has_element?(view, "#running-agent-count-pill", "1 agent running")

    # Verify handle_info updates running count when new task runs
    _task2 =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :running
      })

    send(view.pid, :pipeline_changed)
    assert has_element?(view, "#running-agent-count-pill", "2 agents running")

    # Send unknown info message to test fallback handle_info
    send(view.pid, :unhandled_info_message)
    assert has_element?(view, "#running-agent-count-pill", "2 agents running")
  end

  test "running count with project filter updates via live_sync and pipeline_changed", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: p1_id}} =
             Projects.create_project(scope, %{
               name: "Project P1",
               github_repo: "example/p1-run",
               github_installation_id: 881,
               linear_team_id: "t_p1",
               linear_team_key: "P1R",
               clone_path: "/tmp/p1-run",
               active: true
             })

    assert {:ok, %Project{id: p2_id}} =
             Projects.create_project(scope, %{
               name: "Project P2",
               github_repo: "example/p2-run",
               github_installation_id: 882,
               linear_team_id: "t_p2",
               linear_team_key: "P2R",
               clone_path: "/tmp/p2-run",
               active: true
             })

    _task1 =
      create_test_task(%{
        project_id: p1_id,
        stage: :engineer,
        stage_state: :running
      })

    _task2 =
      create_test_task(%{
        project_id: p2_id,
        stage: :engineer,
        stage_state: :running
      })

    # When viewing P1 only, running count should be 1
    assert {:ok, view, _html} = live(authed_conn, ~p"/?project=#{p1_id}")
    assert has_element?(view, "#running-agent-count-pill", "1 agent running")

    # Send live_sync message
    send(view.pid, {:live_sync, %{table: "tasks"}})
    assert has_element?(view, "#running-agent-count-pill", "1 agent running")

    # Send event map message
    send(view.pid, %{event: "pipeline_changed"})
    assert has_element?(view, "#running-agent-count-pill", "1 agent running")
  end

  test "renders empty state 'All clear' when no tasks wait and no agents run, hiding merged tasks", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Empty App",
               github_repo: "example/empty",
               github_installation_id: 991,
               linear_team_id: "t_empty",
               linear_team_key: "EMP",
               clone_path: "/tmp/empty",
               active: true
             })

    %Task{id: merged_id, title: merged_title} =
      create_test_task(%{
        project_id: project_id,
        stage: :merged,
        stage_state: :queued,
        title: "Already Merged Task"
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

  test "renders dispatch banner when AXIS_NO_DISPATCH=1 and when Dispatcher is disabled", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)

    System.put_env("AXIS_NO_DISPATCH", "1")
    on_exit(fn -> System.delete_env("AXIS_NO_DISPATCH") end)

    assert {:ok, view, _html} = live(authed_conn, ~p"/")
    assert has_element?(view, "#dispatch-disabled-banner")
    assert render(view) =~ "AXIS_NO_DISPATCH=1 is set"

    System.delete_env("AXIS_NO_DISPATCH")

    Dispatcher.set_dispatch_disabled(true)
    on_exit(fn -> Dispatcher.set_dispatch_disabled(false) end)

    assert {:ok, view2, _html} = live(authed_conn, ~p"/")
    assert has_element?(view2, "#dispatch-disabled-banner")

    Dispatcher.set_dispatch_disabled(false)
    assert {:ok, view3, _html} = live(authed_conn, ~p"/")
    refute has_element?(view3, "#dispatch-disabled-banner")
  end

  test "renders question card with options, handles answer clicks, text submission, and dismissal", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Question App",
               github_repo: "example/qapp",
               github_installation_id: 992,
               linear_team_id: "t_q",
               linear_team_key: "QST",
               clone_path: "/tmp/qapp",
               active: true
             })

    %Role{id: role_id} =
      create_test_role(%{
        project_id: project_id,
        stage: :engineer,
        name: "Backend Engineer"
      })

    %Task{id: task_id, title: _task_title} =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :blocked,
        title: "Build Graph API"
      })

    _role_run = create_test_role_run(%{task_id: task_id, role_id: role_id, status: :blocked_on_input})

    %Question{id: _q1_id, prompt: q1_prompt} =
      create_test_question(%{
        task_id: task_id,
        role_id: role_id,
        prompt: "Which database adapter?",
        options: ["Postgres", "SQLite"],
        context_summary: "We need persistent storage for logs",
        status: :pending
      })

    %Question{id: q_orphan_id, prompt: q_orphan_prompt} =
      create_test_question(%{
        task_id: nil,
        prompt: "Orphan clarification prompt?",
        options: ["Option Alpha", "Option Beta"],
        status: :pending
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/")

    assert has_element?(view, "#question-card-task-#{task_id}")
    assert has_element?(view, "#question-card-question-#{q_orphan_id}")
    assert has_element?(view, "#waiting-header", "WAITING ON YOU · 2")
    assert render(view) =~ q1_prompt
    assert render(view) =~ "We need persistent storage for logs"
    assert render(view) =~ q_orphan_prompt

    # Click option button to answer q1
    view
    |> element("#question-option-task-#{task_id}-0")
    |> render_click()

    refute has_element?(view, "#question-card-task-#{task_id}")
    assert has_element?(view, "#question-card-question-#{q_orphan_id}")

    # Empty answer text submission guard
    view
    |> form("#answer-form-question-#{q_orphan_id}", %{"question_id" => q_orphan_id, "answer" => "   "})
    |> render_submit()

    assert has_element?(view, "#question-card-question-#{q_orphan_id}")

    # Dismiss question
    view
    |> element("#dismiss-question-question-#{q_orphan_id}")
    |> render_click()

    refute has_element?(view, "#question-card-question-#{q_orphan_id}")
  end

  test "submits question answer text via form", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Form Q App",
               github_repo: "example/formq",
               github_installation_id: 993,
               linear_team_id: "t_fq",
               linear_team_key: "FQA",
               clone_path: "/tmp/formq",
               active: true
             })

    %Role{id: role_id} =
      create_test_role(%{
        project_id: project_id,
        stage: :engineer,
        name: "Form Engineer"
      })

    %Task{id: task_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :blocked,
        title: "Freeform Task"
      })

    _role_run = create_test_role_run(%{task_id: task_id, role_id: role_id, status: :blocked_on_input})

    %Question{id: q_id} =
      create_test_question(%{
        task_id: task_id,
        role_id: role_id,
        prompt: "What port number?",
        options: [],
        status: :pending
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/")
    assert has_element?(view, "#question-card-task-#{task_id}")

    view
    |> form("#answer-form-task-#{task_id}", %{"question_id" => q_id, "answer" => "4000"})
    |> render_submit()

    refute has_element?(view, "#question-card-task-#{task_id}")
  end

  test "renders approval cards for stages and handles send back comments flow", %{conn: conn} do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Approval App",
               github_repo: "example/approval",
               github_installation_id: 994,
               linear_team_id: "t_appr",
               linear_team_key: "APR",
               clone_path: "/tmp/approval",
               active: true
             })

    _role_arch = create_test_role(%{project_id: project_id, stage: :architect, name: "Architect"})
    _role_prod = create_test_role(%{project_id: project_id, stage: :product, name: "Product"})
    _role_eng = create_test_role(%{project_id: project_id, stage: :engineer, name: "Engineer"})

    %Task{id: arch_id, title: arch_title} =
      create_test_task(%{
        project_id: project_id,
        stage: :architect,
        stage_state: :awaiting_approval,
        title: "Architect Approval Task",
        error: "Architect notes here"
      })

    %Task{id: prod_id, title: prod_title} =
      create_test_task(%{
        project_id: project_id,
        stage: :product,
        stage_state: :awaiting_approval,
        title: "Product Approval Task"
      })

    %Task{id: eng_id, title: eng_title} =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :awaiting_approval,
        title: "Engineer Approval Task"
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
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Compact App",
               github_repo: "example/compact",
               github_installation_id: 995,
               linear_team_id: "t_c",
               linear_team_key: "CMP",
               clone_path: "/tmp/compact",
               active: true
             })

    %Task{id: failed_id, title: failed_title} =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :failed,
        title: "Failed Build Task",
        error: "Compilation error in worker.ex"
      })

    %Task{id: merge_id, title: merge_title} =
      create_test_task(%{
        project_id: project_id,
        stage: :ready_to_merge,
        stage_state: :queued,
        title: "Ready PR Task",
        pr_number: nil
      })

    %Task{id: conflict_id, title: conflict_title} =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :queued,
        mergeability: :conflicting,
        title: "Conflicted Branch Task"
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
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Agent App",
               github_repo: "example/agentapp",
               github_installation_id: 996,
               linear_team_id: "t_ag",
               linear_team_key: "AGP",
               clone_path: "/tmp/agentapp",
               active: true
             })

    %Task{id: t_queued_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :design,
        stage_state: :queued,
        title: "Queued Design Task"
      })

    %Task{id: t_rebase_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :running,
        is_rebasing: true,
        title: "Active Rebasing Task"
      })

    %Task{id: t_running_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :engineer,
        stage_state: :running,
        title: "Active Coding Task"
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
       %{
         conn: conn
       } do
    {authed_conn, user} = log_in_test_user(conn)
    scope = Scope.for_user(user)

    assert {:ok, %Project{id: project_id, name: project_name}} =
             Projects.create_project(scope, %{
               name: "Roster Project",
               github_repo: "example/roster",
               github_installation_id: 997,
               linear_team_id: "t_rst",
               linear_team_key: "RST",
               clone_path: "/tmp/roster",
               active: true
             })

    %Role{id: r_eng_id} =
      create_test_role(%{
        project_id: project_id,
        stage: :engineer,
        name: "Software Engineer",
        icon_name: nil
      })

    %Role{id: r_arch_id} =
      create_test_role(%{
        project_id: project_id,
        stage: :architect,
        name: "System Architect",
        icon_name: nil
      })

    %Role{id: r_des_id} =
      create_test_role(%{
        project_id: project_id,
        stage: :design,
        name: "UI Designer",
        icon_name: nil
      })

    %Role{id: r_qa_id} =
      create_test_role(%{
        project_id: project_id,
        stage: :qa,
        name: "QA Specialist",
        icon_name: nil
      })

    %Role{id: r_demo_id} =
      create_test_role(%{
        project_id: project_id,
        stage: :demo,
        name: "Demo Recorder",
        icon_name: nil
      })

    %Role{id: r_custom_id} =
      create_test_role(%{
        project_id: project_id,
        stage: nil,
        name: "Custom Bot",
        icon_name: "smart_toy"
      })

    %Role{id: r_prod_id} =
      create_test_role(%{
        project_id: project_id,
        stage: :product,
        name: "Product Manager",
        icon_name: nil
      })

    %Issue{id: issue_id, identifier: issue_identifier} =
      create_test_issue(%{project_id: project_id, identifier: "ENG-101"})

    # Running task for Engineer with associated issue
    %Task{id: t_eng_id} =
      create_test_task(%{
        project_id: project_id,
        issue_id: issue_id,
        stage: :engineer,
        stage_state: :running,
        title: "Writing Tests"
      })

    # Chatting task for Architect
    %Task{id: t_arch_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :architect,
        stage_state: :running,
        active_chat_role_id: r_arch_id,
        title: "Brainstorming Architecture"
      })

    # Waiting task for QA
    %Task{id: t_qa_id} =
      create_test_task(%{
        project_id: project_id,
        stage: :qa,
        stage_state: :awaiting_approval,
        title: "Verify Slice 5.2"
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
    task = create_test_task(%{title: "Other Kind Task"})
    task_with_issue = %{task | issue: %Issue{identifier: "ISS-42"}}
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
      title: "Rebase In Agent",
      is_rebasing: true,
      stage_state: :running,
      stage: :engineer,
      updated_at: now
    }

    task_blocked = %Task{
      id: "tsk_blk_1",
      title: "Blocked In Agent",
      stage_state: :blocked,
      stage: :engineer,
      updated_at: now
    }

    task_approval = %Task{
      id: "tsk_appr_1",
      title: "Approval In Agent",
      stage_state: :awaiting_approval,
      stage: :architect,
      updated_at: now
    }

    task_failed = %Task{
      id: "tsk_fail_1",
      title: "Failed In Agent",
      stage_state: :failed,
      stage: :engineer,
      issue: %Issue{identifier: "WAG-100"},
      updated_at: now
    }

    task_other = %Task{
      id: "tsk_other_1",
      title: "Other In Agent",
      stage_state: :running,
      stage: nil,
      updated_at: now
    }

    task_role = %{
      id: "tsk_role_map",
      title: "Map with role",
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
      title: "Default Diff Task",
      stage: :review,
      stage_state: :awaiting_approval,
      issue: %Issue{identifier: "APP-50"},
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
      title: "Plain Task",
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
      title: "Question Task",
      stage: :architect,
      issue: %Issue{identifier: "QST-88"}
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
