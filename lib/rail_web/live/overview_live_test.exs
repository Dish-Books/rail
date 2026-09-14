defmodule RailWeb.OverviewLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.DetectedQuestion
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Users

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
    assert has_element?(view, "#overview-stats")

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

    assert {:ok, %Project{id: project_id, name: project_name}} =
             Projects.create_project(scope, %{
               name: "Preset Project",
               github_repo: "example/preset",
               github_installation_id: 333,
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

  describe "the overview, which reads runs and the tasks they belong to" do
    setup %{conn: conn} do
      {:ok, user} =
        Users.register_oauth_user(%{
          github_id: "gh_overview_queue",
          login: "overview_queue_user",
          email: "overview_queue_user@example.com",
          admin: true
        })

      scope = Scope.for_user(user)

      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
      end)

      {:ok, project} =
        Projects.create_project(scope, %{
          name: "Queue App",
          github_repo: "example/queue",
          github_installation_id: 909,
          linear_workspace: %{
            name: "Overview Queue Workspace",
            external_id: "lin_ws_overview_queue",
            token: "lin_api_token_overview_queue",
            webhook_secret: "whsec_overview_queue"
          },
          linear_team_key: "QUE",
          default_branch: "main",
          clone_path: "/tmp/queue",
          active: true,
          linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
        })

      {:ok, backend} =
        Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

      roles =
        Map.new([:product, :architect, :engineer, :qa], fn stage ->
          {:ok, role} =
            Roles.create_role(scope, project, %{
              backend_id: backend.id,
              stage: stage,
              name: "#{stage} role",
              model: "claude-3-7-sonnet",
              system_prompt: "You are the #{stage} agent."
            })

          {stage, role}
        end)

      # Each issue created answers Linear once, under a key of its own. A
      # `:completed_at` is Linear completing the issue.
      task_for = fn title, attrs ->
        {completed_at, attrs} = Map.pop(attrs, :completed_at)
        n = System.unique_integer([:positive])

        Req.Test.expect(Rail.Linear, fn conn ->
          Req.Test.json(conn, %{
            "data" => %{
              "issueCreate" => %{
                "success" => true,
                "issue" => %{"id" => "lin_queue_#{n}", "identifier" => "QUE-#{n}", "title" => title}
              }
            }
          })
        end)

        {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: title})
        issue = issue |> Issue.linear_changeset(%{completed_at: completed_at}) |> Repo.update!()
        {:ok, task} = Pipeline.create_task(issue, :product)
        {:ok, task} = Pipeline.update_task(task, attrs)
        Repo.preload(task, :issue)
      end

      %{conn: log_in_user(conn, user), project: project, roles: roles, task_for: task_for}
    end

    test "with nothing going on, nothing waits and every role is idle", %{
      conn: conn,
      project: project,
      roles: roles
    } do
      assert {:ok, view, _html} = live(conn, ~p"/?project=#{project.id}")

      assert has_element?(view, "#stat-in-progress [data-qa='stat-value']", "0")
      assert has_element?(view, "#stat-shipped-delta", "same as prior 30")
      refute has_element?(view, "#stat-oldest-waiting")
      assert has_element?(view, "#up-next-empty", "Nothing is waiting on you.")
      assert has_element?(view, "#activity-feed-empty")
      assert has_element?(view, "#roster-running-count", "0 / 4 running")
      assert has_element?(view, "#role-row-#{roles[:qa].id}[data-tone='idle']", "Idle · no work assigned")
      assert has_element?(view, "#throughput-total", "0 total")
      refute has_element?(view, "[data-qa='roster-project-header']")
    end

    test "the numbers across the top count what is in flight, what shipped and what waits", %{
      conn: conn,
      roles: roles,
      task_for: task_for
    } do
      now = DateTime.utc_now()
      waiting = task_for.("Waiting work", %{})

      {:ok, _run} =
        Pipeline.create_run(%{
          task_id: waiting.id,
          role_id: roles[:product].id,
          status: :finished,
          stage_outcome: :done,
          started_at: DateTime.shift(now, hour: -3),
          completed_at: DateTime.shift(now, second: -(2 * 3600 + 14 * 60))
        })

      task_for.("Shipped today", %{completed_at: now})
      task_for.("Shipped this month", %{completed_at: DateTime.shift(now, day: -5)})
      task_for.("Shipped last month", %{completed_at: DateTime.shift(now, day: -45)})

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#stat-in-progress [data-qa='stat-value']", "1")
      assert has_element?(view, "#stat-shipped [data-qa='stat-value']", "2")
      assert has_element?(view, "#stat-shipped-delta", "+1 vs prior 30")
      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "1")
      assert has_element?(view, "#stat-oldest-waiting", "oldest 2h 14m")

      assert has_element?(view, "#throughput-total", "2 total")
      assert view |> render() |> :binary.matches("data-qa=\"throughput-bar\"") |> length() == 30

      # Unfiltered, the roster names the project each group of roles belongs to.
      assert has_element?(view, "[data-qa='roster-project-header']", "Queue App")
    end

    test "up next leads with the longest-waiting run, and every entry only links to its task", %{
      conn: conn,
      roles: roles,
      task_for: task_for
    } do
      now = DateTime.utc_now()

      review = task_for.("Ticket to review", %{})

      {:ok, review_run} =
        Pipeline.create_run(%{
          task_id: review.id,
          role_id: roles[:product].id,
          status: :finished,
          stage_outcome: :done,
          started_at: DateTime.shift(now, hour: -4),
          completed_at: DateTime.shift(now, hour: -3)
        })

      blocked_run = fn title, role, prompts, stopped_at ->
        task = task_for.(title, %{stage: role.stage})

        {:ok, run} =
          Pipeline.create_run(%{
            task_id: task.id,
            role_id: role.id,
            status: :running,
            conversation_id: "sess_#{System.unique_integer([:positive])}",
            started_at: DateTime.shift(stopped_at, minute: -30)
          })

        for prompt <- prompts do
          {:ok, _question} =
            Pipeline.register_question(Repo.preload(run, task: :issue), %DetectedQuestion{prompt: prompt})
        end

        {:ok, blocked} = Pipeline.get_run(run.id)
        {:ok, stopped} = Pipeline.update_run(blocked, %{completed_at: stopped_at})
        {task, stopped}
      end

      {one_task, one_question} =
        blocked_run.("Naming decision", roles[:architect], ["Which name?"], DateTime.shift(now, hour: -2))

      {two_task, two_questions} =
        blocked_run.("Two decisions", roles[:engineer], ["Which db?", "Behind a flag?"], DateTime.shift(now, hour: -1))

      assert {:ok, view, html} = live(conn, ~p"/")

      assert has_element?(view, "#up-next-featured-#{review_run.id}[href='/tasks/#{review.id}']", "Ticket to review")
      assert has_element?(view, "#up-next-featured-#{review_run.id} [data-qa='up-next-chip']", "Ready for review")
      assert has_element?(view, "#up-next-featured-#{review_run.id}", "Review ticket")

      assert has_element?(view, "#up-next-row-#{one_question.id}[href='/tasks/#{one_task.id}']", "asked a question")
      assert has_element?(view, "#up-next-row-#{two_questions.id}[href='/tasks/#{two_task.id}']", "asked 2 questions")
      assert has_element?(view, "#up-next-row-#{two_questions.id}", "Answer")

      positions =
        Enum.map([review_run, one_question, two_questions], fn run ->
          html |> :binary.match(run.id) |> elem(0)
        end)

      assert positions == Enum.sort(positions)

      # Answering happens on the task, never here.
      refute has_element?(view, "[data-qa='answer-input']")

      assert has_element?(view, "#stat-oldest-waiting", "oldest 3h 0m")
      assert has_element?(view, "#role-row-#{roles[:product].id}[data-tone='waiting']", "Handed off")
      assert has_element?(view, "#role-row-#{roles[:architect].id}[data-tone='waiting']", "Blocked")

      assert has_element?(view, "#activity-ended-#{review_run.id}", "back for review")
      assert has_element?(view, "#activity-asked-#{one_question.id}", "asked a question")
      assert has_element?(view, "#activity-asked-#{two_questions.id}", "asked 2 questions")
    end

    test "a run whose questions are all answered leads as ready to send", %{
      conn: conn,
      roles: roles,
      task_for: task_for
    } do
      task = task_for.("Answered work", %{})

      {:ok, run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:product].id,
          status: :running,
          conversation_id: "sess_answered",
          started_at: DateTime.utc_now()
        })

      {:ok, question} =
        Pipeline.register_question(Repo.preload(run, task: :issue), %DetectedQuestion{prompt: "Which one?"})

      {:ok, _answered} = Pipeline.answer_question(question, "That one")

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#up-next-featured-#{run.id} [data-qa='up-next-chip']", "Needs an answer")
      assert has_element?(view, "#up-next-featured-#{run.id} [data-qa='up-next-summary']", "ready to send")
      assert has_element?(view, "#up-next-featured-#{run.id}", "Answer questions")
    end

    test "a run waiting on a pending question leads with that question", %{
      conn: conn,
      roles: roles,
      task_for: task_for
    } do
      task = task_for.("Pending work", %{})

      {:ok, run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:product].id,
          status: :running,
          conversation_id: "sess_pending",
          started_at: DateTime.utc_now()
        })

      {:ok, _question} =
        Pipeline.register_question(Repo.preload(run, task: :issue), %DetectedQuestion{prompt: "Which database?"})

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#up-next-featured-#{run.id} [data-qa='up-next-summary']", "Which database?")
    end

    test "since yesterday lists what runs did and what shipped, newest first, and roles read the same runs", %{
      conn: conn,
      roles: roles,
      task_for: task_for
    } do
      now = DateTime.utc_now()

      running_task = task_for.("Running work", %{stage: :engineer})

      {:ok, running} =
        Pipeline.create_run(%{
          task_id: running_task.id,
          role_id: roles[:engineer].id,
          status: :running,
          started_at: DateTime.shift(now, minute: -10)
        })

      failed_task = task_for.("Failed work", %{stage: :qa})

      {:ok, failed} =
        Pipeline.create_run(%{
          task_id: failed_task.id,
          role_id: roles[:qa].id,
          status: :failed,
          error: "Exited with code 2",
          started_at: DateTime.shift(now, hour: -5),
          completed_at: DateTime.shift(now, hour: -4)
        })

      stopped_task = task_for.("Stopped work", %{stage: :architect})

      {:ok, stopped} =
        Pipeline.create_run(%{
          task_id: stopped_task.id,
          role_id: roles[:architect].id,
          status: :finished,
          started_at: DateTime.shift(now, hour: -4),
          completed_at: DateTime.shift(now, hour: -3)
        })

      moved_on = task_for.("Moved on work", %{stage: :architect})

      {:ok, finished} =
        Pipeline.create_run(%{
          task_id: moved_on.id,
          role_id: roles[:product].id,
          status: :finished,
          stage_outcome: :done,
          started_at: DateTime.shift(now, hour: -3),
          completed_at: DateTime.shift(now, hour: -2)
        })

      shipped = task_for.("Shipped work", %{completed_at: DateTime.shift(now, hour: -1)})

      old_task = task_for.("Old work", %{stage: :architect})

      {:ok, old} =
        Pipeline.create_run(%{
          task_id: old_task.id,
          role_id: roles[:architect].id,
          status: :finished,
          started_at: DateTime.shift(now, day: -3),
          completed_at: DateTime.shift(now, day: -3)
        })

      assert {:ok, view, html} = live(conn, ~p"/")

      assert has_element?(view, "#activity-started-#{running.id}", "engineer role")
      assert has_element?(view, "#activity-started-#{running.id}", "started on #{running_task.issue.identifier}")
      refute has_element?(view, "#activity-ended-#{running.id}")
      assert has_element?(view, "#activity-ended-#{failed.id}", "failed on")
      assert has_element?(view, "#activity-ended-#{stopped.id}", "stopped on")
      assert has_element?(view, "#activity-ended-#{finished.id}", "finished on")
      assert has_element?(view, "#activity-shipped-#{shipped.issue.id}", "#{shipped.issue.identifier} shipped")
      refute has_element?(view, "#activity-started-#{old.id}")

      positions =
        Enum.map(
          ["activity-shipped-#{shipped.issue.id}", "activity-ended-#{finished.id}", "activity-ended-#{stopped.id}"],
          fn id ->
            html |> :binary.match(id) |> elem(0)
          end
        )

      assert positions == Enum.sort(positions)

      assert has_element?(view, "#roster-running-count", "1 / 4 running")
      assert has_element?(view, "#role-row-#{roles[:engineer].id}[data-tone='running']", "Running")
      assert has_element?(view, "#role-row-#{roles[:qa].id}[data-tone='failed']", "Failed 4h 0m ago")
      assert has_element?(view, "#role-row-#{roles[:architect].id}[data-tone='idle']", "Last ran 3h 0m ago")
      assert has_element?(view, "#role-row-#{roles[:product].id}[href='/tasks/#{moved_on.id}']", "Last ran 2h 0m ago")
    end

    test "a merged task waits on nobody", %{conn: conn, roles: roles, task_for: task_for} do
      task = task_for.("Shipped work", %{stage: :merged, merged_at: DateTime.utc_now()})

      {:ok, _run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          status: :finished,
          stage_outcome: :done,
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        })

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#up-next-empty")
    end

    test "the dispatch banner shows while dispatch is switched off", %{conn: conn} do
      previous = Application.get_env(:rail, :no_dispatch)
      Application.put_env(:rail, :no_dispatch, true)
      on_exit(fn -> Application.put_env(:rail, :no_dispatch, previous) end)

      assert {:ok, view, _html} = live(conn, ~p"/")
      assert render(view) =~ "RAIL_NO_DISPATCH=1 is set"
    end

    test "a project that no longer exists shows no roster", %{conn: conn, roles: roles} do
      assert {:ok, view, _html} = live(conn, ~p"/?project=prj_missing")

      refute has_element?(view, "#role-row-#{roles[:product].id}")
    end
  end
end
