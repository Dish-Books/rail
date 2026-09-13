defmodule RailWeb.OverviewLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.DetectedQuestion
  alias Rail.Pipeline.Schemas.Question
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

  describe "the queue, which is a list of runs" do
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
        Map.new([:product, :engineer], fn stage ->
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

      %{conn: log_in_user(conn, user), scope: scope, project: project, roles: roles}
    end

    test "a run that is working shows under WITH AN AGENT and counts as running", %{
      conn: conn,
      project: project,
      roles: roles
    } do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{
                "id" => "lin_queue_running",
                "identifier" => "QUE-1",
                "title" => "Running work"
              }
            }
          }
        })
      end)

      {:ok, issue} = Issues.create_issue(project, %{description: "Running work"})
      {:ok, task} = Pipeline.create_task(issue, :product)
      {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})

      {:ok, _run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#running-agent-count-pill", "1 agent running")
      assert has_element?(view, "#with-agent-section")
      assert has_element?(view, "[data-qa='with-agent-state-pill']", "Running")
      assert has_element?(view, "[data-qa='with-agent-title']", "Running work")
      refute has_element?(view, "#waiting-on-you-section")
    end

    test "the runs waiting are listed longest-waiting first", %{
      conn: conn,
      project: project,
      roles: roles
    } do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{
                "id" => "lin_queue_order",
                "identifier" => "QUE-9",
                "title" => "Ordering"
              }
            }
          }
        })
      end)

      {:ok, issue} = Issues.create_issue(project, %{description: "Ordering"})

      waiting_run = fn stopped_at ->
        {:ok, task} = Pipeline.create_task(issue, :product)

        {:ok, run} =
          Pipeline.create_run(%{
            task_id: task.id,
            role_id: roles[:product].id,
            status: :running,
            conversation_id: "sess_#{System.unique_integer([:positive])}",
            started_at: DateTime.utc_now()
          })

        run = Repo.preload(run, task: :issue)
        {:ok, _question} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Which one?"})

        {:ok, blocked} = Pipeline.get_run(run.id)
        {:ok, stopped} = Pipeline.update_run(blocked, %{completed_at: stopped_at})
        stopped
      end

      recent = waiting_run.(~U[2026-01-01 11:00:00Z])
      oldest = waiting_run.(~U[2026-01-01 09:00:00Z])
      middle = waiting_run.(~U[2026-01-01 10:00:00Z])

      assert {:ok, view, html} = live(conn, ~p"/")

      assert has_element?(view, "#waiting-on-you-section")

      positions =
        Enum.map([oldest, middle, recent], fn run ->
          html |> :binary.match("question-card-#{run.id}") |> elem(0)
        end)

      assert positions == Enum.sort(positions)
    end

    test "a blocked run shows every question it asked, and only sends once none are pending", %{
      conn: conn,
      project: project,
      roles: roles
    } do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{
                "id" => "lin_queue_blocked",
                "identifier" => "QUE-4",
                "title" => "Needs answers"
              }
            }
          }
        })
      end)

      {:ok, issue} = Issues.create_issue(project, %{description: "Needs answers"})
      {:ok, task} = Pipeline.create_task(issue, :product)

      {:ok, run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:product].id,
          status: :running,
          conversation_id: "sess_blocked",
          started_at: DateTime.utc_now()
        })

      run = Repo.preload(run, task: :issue)

      {:ok, %Question{id: first_id}} =
        Pipeline.register_question(run, %DetectedQuestion{prompt: "Which database?"})

      {:ok, %Question{id: second_id}} =
        Pipeline.register_question(run, %DetectedQuestion{prompt: "Ship behind a flag?"})

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "[data-qa='overview-card question-card']")
      assert has_element?(view, "[data-qa='question-prompt']", "Which database?")
      assert has_element?(view, "[data-qa='question-prompt']", "Ship behind a flag?")
      assert has_element?(view, "[data-qa='questions-pending-note']", "2 still to answer")
      assert has_element?(view, "[data-qa='send-answers-button'][disabled]")

      view
      |> element("#answer-form-#{first_id}")
      |> render_submit(%{"question_id" => first_id, "answer" => "Postgres"})

      assert has_element?(view, "[data-qa='question-answer']", "Postgres")
      assert has_element?(view, "[data-qa='questions-pending-note']", "1 still to answer")
      assert has_element?(view, "[data-qa='send-answers-button'][disabled]")

      view
      |> element("#dismiss-question-#{second_id}")
      |> render_click()

      assert has_element?(view, "[data-qa='question-dismissed']")
      refute has_element?(view, "[data-qa='send-answers-button'][disabled]")

      view |> element("#send-answers-#{run.id}") |> render_click()

      assert %Question{delivered_at: %DateTime{}} = Repo.get!(Question, first_id)
      assert %Question{delivered_at: %DateTime{}} = Repo.get!(Question, second_id)
    end

    test "a merged task waits on nobody", %{conn: conn, project: project, roles: roles} do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{
                "id" => "lin_queue_merged",
                "identifier" => "QUE-6",
                "title" => "Shipped work"
              }
            }
          }
        })
      end)

      {:ok, issue} = Issues.create_issue(project, %{description: "Shipped work"})
      {:ok, task} = Pipeline.create_task(issue, :product)
      {:ok, task} = Pipeline.update_task(task, %{stage: :merged, merged_at: DateTime.utc_now()})

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

      assert has_element?(view, "#overview-empty-state")
      refute has_element?(view, "#waiting-on-you-section")
    end

    test "the role roster reads each role's own run", %{conn: conn, project: project, roles: roles} do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{
                "id" => "lin_queue_roster",
                "identifier" => "QUE-7",
                "title" => "Roster work"
              }
            }
          }
        })
      end)

      {:ok, issue} = Issues.create_issue(project, %{description: "Roster work"})
      {:ok, task} = Pipeline.create_task(issue, :product)
      {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})

      {:ok, _run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert {:ok, view, _html} = live(conn, ~p"/?project=#{project.id}")

      assert has_element?(view, "#role-row-#{roles[:engineer].id}", "QUE-7 · running")
      assert has_element?(view, "#role-idle-#{roles[:product].id}", "Idle")
    end

    test "the dispatch banner shows while dispatch is switched off", %{conn: conn} do
      previous = Application.get_env(:rail, :no_dispatch)
      Application.put_env(:rail, :no_dispatch, true)
      on_exit(fn -> Application.put_env(:rail, :no_dispatch, previous) end)

      assert {:ok, view, _html} = live(conn, ~p"/")
      assert render(view) =~ "RAIL_NO_DISPATCH=1 is set"
    end

    test "answering by picking one of the options offered", %{conn: conn, project: project, roles: roles} do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{
                "id" => "lin_queue_options",
                "identifier" => "QUE-11",
                "title" => "Option work"
              }
            }
          }
        })
      end)

      {:ok, issue} = Issues.create_issue(project, %{description: "Option work"})
      {:ok, task} = Pipeline.create_task(issue, :product)

      {:ok, run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:product].id,
          status: :running,
          conversation_id: "sess_options",
          started_at: DateTime.utc_now()
        })

      {:ok, question} =
        Pipeline.register_question(Repo.preload(run, task: :issue), %DetectedQuestion{
          prompt: "Which database?",
          options: ["Postgres", "Sqlite"]
        })

      assert {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#question-option-#{question.id}-0") |> render_click()

      assert %Question{status: :answered, answer: "Postgres"} = Repo.reload!(question)
    end

    test "a blank answer is not recorded", %{conn: conn, project: project, roles: roles} do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{
                "id" => "lin_queue_blank",
                "identifier" => "QUE-12",
                "title" => "Blank work"
              }
            }
          }
        })
      end)

      {:ok, issue} = Issues.create_issue(project, %{description: "Blank work"})
      {:ok, task} = Pipeline.create_task(issue, :product)

      {:ok, run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:product].id,
          status: :running,
          conversation_id: "sess_blank",
          started_at: DateTime.utc_now()
        })

      {:ok, question} =
        Pipeline.register_question(Repo.preload(run, task: :issue), %DetectedQuestion{prompt: "Which database?"})

      assert {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#answer-form-#{question.id}") |> render_submit(%{"question_id" => question.id, "answer" => "  "})

      assert %Question{status: :pending} = Repo.reload!(question)
    end
  end
end
