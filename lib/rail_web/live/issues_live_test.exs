defmodule RailWeb.IssuesLiveTest do
  use RailWeb.ConnCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Phoenix.LiveViewTest

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.SyncProjectIssues
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users

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

    assert {:ok, %Project{id: project_id, name: project_name}} =
             Projects.create_project(scope, %{
               linear_workspace: %{
                 name: "Issues Live Workspace 13212",
                 external_id: "lin_ws_issues_live_13212_x7",
                 token: "lin_api_token_issues_live_13212",
                 webhook_secret: "whsec_issues_live_13212"
               },
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

  test "renders issue cards with all attributes, badges, full body, and worktree", %{
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

    assert {:ok, %Project{id: _project_id} = project} =
             Projects.create_project(scope, %{
               linear_workspace: %{
                 name: "Issues Live Workspace 13212",
                 external_id: "lin_ws_issues_live_13212_x8",
                 token: "lin_api_token_issues_live_13212",
                 webhook_secret: "whsec_issues_live_13212"
               },
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

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_issues_live_13201",
              "identifier" => "DEMO-101",
              "title" => "Demo title"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(project, %{title: "Demo title"})

    {:ok, issue} =
      Issues.update_issue(issue, %{
        description: "Demo title\nDetailed explanation of the issue.",
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
    assert has_element?(view, "#issue-card-#{issue.id} [data-qa='issue-title']", "Demo title")
    assert has_element?(view, "#issue-card-#{issue.id} [data-qa='issue-priority-badge']", "Urgent")
    assert has_element?(view, "#issue-card-#{issue.id} [data-qa='issue-status-badge']", "In Progress")

    assert has_element?(
             view,
             "#issue-card-#{issue.id} [data-qa='issue-body']",
             ~r/Demo title\s+Detailed explanation of the issue\./
           )

    assert has_element?(
             view,
             "#issue-card-#{issue.id} [data-qa='issue-worktree']",
             "Dedicated Worktree: .worktrees/feat-demo-101"
           )

    assert has_element?(view, "#start-product-run-#{issue.id}", "Start")
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

    assert {:ok, %Project{id: _project_id} = project} =
             Projects.create_project(scope, %{
               linear_workspace: %{
                 name: "Issues Live Workspace 13212",
                 external_id: "lin_ws_issues_live_13212_x9",
                 token: "lin_api_token_issues_live_13212",
                 webhook_secret: "whsec_issues_live_13212"
               },
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

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_issues_live_13202",
              "identifier" => "PRIO-1",
              "title" => "Urgent issue"
            }
          }
        }
      })
    end)

    {:ok, issue_urgent} = Issues.create_issue(project, %{title: "Urgent issue"})

    {:ok, issue_urgent} =
      Issues.update_issue(issue_urgent, %{
        priority: :urgent,
        state: :backlog
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_issues_live_13203",
              "identifier" => "PRIO-2",
              "title" => "High issue 1"
            }
          }
        }
      })
    end)

    {:ok, issue_high_1} = Issues.create_issue(project, %{title: "High issue 1"})

    {:ok, issue_high_1} =
      Issues.update_issue(issue_high_1, %{
        priority: :high,
        state: :backlog
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_issues_live_13204",
              "identifier" => "PRIO-3",
              "title" => "High issue 2"
            }
          }
        }
      })
    end)

    {:ok, issue_high_2} = Issues.create_issue(project, %{title: "High issue 2"})

    {:ok, issue_high_2} =
      Issues.update_issue(issue_high_2, %{
        priority: :high,
        state: :backlog
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_issues_live_13205",
              "identifier" => "PRIO-4",
              "title" => "Low issue"
            }
          }
        }
      })
    end)

    {:ok, issue_low} = Issues.create_issue(project, %{title: "Low issue"})

    {:ok, issue_low} =
      Issues.update_issue(issue_low, %{
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
    assert_patched(view, ~p"/issues?priority=high")
    refute has_element?(view, "#issue-card-#{issue_urgent.id}")
    assert has_element?(view, "#issue-card-#{issue_high_1.id}")
    assert has_element?(view, "#issue-card-#{issue_high_2.id}")
    refute has_element?(view, "#issue-card-#{issue_low.id}")

    # Clicking High again keeps it filtered; only the All chip clears
    view |> element("#filter-priority-high") |> render_click()
    refute has_element?(view, "#issue-card-#{issue_urgent.id}")
    assert has_element?(view, "#issue-card-#{issue_high_1.id}")

    # Select Urgent filter
    view |> element("#filter-priority-urgent") |> render_click()
    assert has_element?(view, "#issue-card-#{issue_urgent.id}")
    refute has_element?(view, "#issue-card-#{issue_high_1.id}")

    # Click All chip resets
    view |> element("#filter-priority-all") |> render_click()
    assert_patched(view, ~p"/issues")
    assert has_element?(view, "#issue-card-#{issue_urgent.id}")
    assert has_element?(view, "#issue-card-#{issue_high_1.id}")

    # A priority that is not one of ours is no filter at all
    view |> element("#filter-priority-all") |> render_click(%{"priority" => "invalid_prio"})
    assert has_element?(view, "#issue-card-#{issue_urgent.id}")
    assert has_element?(view, "#issue-card-#{issue_high_1.id}")
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

    assert {:ok, %Project{id: _project_id} = project} =
             Projects.create_project(scope, %{
               linear_workspace: %{
                 name: "Issues Live Workspace 13212",
                 external_id: "lin_ws_issues_live_13212_x10",
                 token: "lin_api_token_issues_live_13212",
                 webhook_secret: "whsec_issues_live_13212"
               },
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

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_issues_live_13206",
              "identifier" => "FIN-1",
              "title" => "Active task"
            }
          }
        }
      })
    end)

    {:ok, active_issue} = Issues.create_issue(project, %{title: "Active task"})

    {:ok, active_issue} =
      Issues.update_issue(active_issue, %{
        state: :in_progress
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_issues_live_13207",
              "identifier" => "FIN-2",
              "title" => "Done task"
            }
          }
        }
      })
    end)

    {:ok, done_issue} = Issues.create_issue(project, %{title: "Done task"})

    {:ok, done_issue} =
      Issues.update_issue(done_issue, %{
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

    assert {:ok, %Project{id: _project_id} = project} =
             Projects.create_project(scope, %{
               name: "Bring Local Project",
               github_repo: "example/bring-local",
               github_installation_id: 704,
               linear_workspace: %{
                 name: "Issues Live Workspace 13212",
                 external_id: "lin_ws_issues_live_13212",
                 token: "lin_api_token_issues_live_13212",
                 webhook_secret: "whsec_issues_live_13212"
               },
               linear_team_id: "t_bl",
               linear_team_key: "BL",
               linear_state_ids: %{"in_progress" => "st_in_prog_bl"},
               default_branch: "main",
               clone_path: "/tmp/bring-local-proj",
               active: true
             })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_bl_1", "identifier" => "BL-10", "title" => "Bring local feature"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(project, %{title: "Bring local feature"})

    {:ok, issue} =
      Issues.update_issue(issue, %{
        state: :backlog
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

    assert {:ok, %Project{id: _project_id} = project} =
             Projects.create_project(scope, %{
               name: "Editor Project",
               github_repo: "example/editor-proj",
               github_installation_id: 705,
               linear_workspace: %{
                 name: "Issues Live Workspace 13213",
                 external_id: "lin_ws_issues_live_13213",
                 token: "lin_api_token_issues_live_13213",
                 webhook_secret: "whsec_issues_live_13213"
               },
               linear_team_id: "t_ed",
               linear_team_key: "ED",
               default_branch: "main",
               clone_path: "/tmp/editor-proj",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_ed_1", "identifier" => "ED-50", "title" => "Initial title"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(project, %{title: "Initial title"})

    {:ok, issue} =
      Issues.update_issue(issue, %{
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

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(scope, %{
               name: "Sync Project",
               github_repo: "example/sync-proj",
               github_installation_id: 707,
               linear_workspace: %{
                 name: "Issues Live Workspace 13215",
                 external_id: "lin_ws_issues_live_13215",
                 token: "lin_api_token_issues_live_13215",
                 webhook_secret: "whsec_issues_live_13215"
               },
               linear_team_id: "t_sync",
               linear_team_key: "SYNC",
               default_branch: "main",
               clone_path: "/tmp/sync-proj",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    # No Linear stub is queued: the click only queues the pull.
    assert {:ok, view, _html} = live(authed_conn, ~p"/issues?project=#{project_id}")

    view |> element("#sync-issues-button") |> render_click()
    assert_enqueued(worker: SyncProjectIssues, args: %{project_id: project_id})
    assert has_element?(view, "#sync-issues-button[disabled]", "Syncing...")

    # The worker saying the last page landed frees the button and shows what came in.
    %Issue{}
    |> Issue.changeset(%{
      project_id: project_id,
      external_id: "lin_synced",
      identifier: "SYNC-1",
      title: "Synced",
      state: :triage
    })
    |> Repo.insert!()

    send(view.pid, {:issues_synced, project_id})
    assert has_element?(view, "#sync-issues-button", "Sync Issues")
    assert has_element?(view, "[data-qa='issue-title']", "Synced")

    # Unfiltered sync covers every project
    assert {:ok, view_all, _html} = live(authed_conn, ~p"/issues")
    view_all |> element("#sync-issues-button") |> render_click()
    assert has_element?(view_all, "#sync-issues-button", "Syncing...")

    send(view_all.pid, {:issues_synced, project_id})
    assert has_element?(view_all, "#sync-issues-button", "Sync Issues")
  end

  test "searches issues from the URL and pages through them", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_13",
        login: "issues_live_user_13",
        email: "issues_live_user_13@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    assert {:ok, %Project{id: project_id}} =
             Projects.create_project(Scope.for_user(user), %{
               name: "Paging Project",
               github_repo: "example/paging-proj",
               github_installation_id: 708,
               linear_workspace: %{
                 name: "Issues Live Workspace 13216",
                 external_id: "lin_ws_issues_live_13216",
                 token: "lin_api_token_issues_live_13216",
                 webhook_secret: "whsec_issues_live_13216"
               },
               linear_team_id: "t_page",
               linear_team_key: "PAGE",
               default_branch: "main",
               clone_path: "/tmp/paging-proj",
               active: true
             })

    [first | _rest] =
      issues =
      Enum.map(1..51, fn n ->
        %Issue{}
        |> Issue.changeset(%{
          project_id: project_id,
          external_id: "lin_page_#{n}",
          identifier: "PAGE-#{n}",
          title: if(n == 51, do: "Fix login redirect", else: "Paged issue #{n}"),
          state: :backlog
        })
        |> Repo.insert!()
      end)

    last = List.last(issues)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    assert has_element?(view, "#filter-priority-all", "All (51)")
    assert has_element?(view, "#issues-page-range", "Showing 1–50 of 51")
    assert has_element?(view, "#issue-card-#{first.id}")
    refute has_element?(view, "#issue-card-#{last.id}")
    refute has_element?(view, "#issues-page-prev")

    view |> element("#issues-page-next") |> render_click()
    assert_patched(view, ~p"/issues?page=2")
    assert has_element?(view, "#issues-page-range", "Showing 51–51 of 51")
    assert has_element?(view, "#issue-card-#{last.id}")
    refute has_element?(view, "#issue-card-#{first.id}")
    refute has_element?(view, "#issues-page-next")

    # Searching goes back to the first page of what matches.
    view |> element("#issues-search-form") |> render_change(%{"q" => "LOGIN"})
    assert_patched(view, ~p"/issues?q=LOGIN")
    assert has_element?(view, "#issues-page-range", "Showing 1–1 of 1")
    assert has_element?(view, "#issue-card-#{last.id}")
    assert has_element?(view, "#issues-search[value='LOGIN']")

    view |> element("#issues-search-form") |> render_submit(%{"q" => "PAGE-12"})
    assert_patched(view, ~p"/issues?q=PAGE-12")
    assert has_element?(view, "[data-qa='issue-identifier']", "PAGE-12")
    refute has_element?(view, "#issue-card-#{last.id}")

    view |> element("#issues-search-form") |> render_change(%{"q" => "nothing like this"})
    assert has_element?(view, "[data-qa='empty-state-title']", "No issues match")
    refute has_element?(view, "#issues-pagination")

    # The URL alone is enough to land on a page; one past the end shows the last,
    # and a bad page number is page one.
    assert {:ok, linked, _html} = live(authed_conn, ~p"/issues?page=2")
    assert has_element?(linked, "#issue-card-#{last.id}")

    assert {:ok, past_end, _html} = live(authed_conn, ~p"/issues?page=9&q=issue")
    assert has_element?(past_end, "#issues-page-range", "Showing 1–50 of 50")

    assert {:ok, bad_page, _html} = live(authed_conn, ~p"/issues?page=nope")
    assert has_element?(bad_page, "#issues-page-range", "Showing 1–50 of 51")
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

    assert {:ok, %Project{id: p_id, name: p_name}} =
             Projects.create_project(scope, %{
               linear_workspace: %{
                 name: "Issues Live Workspace 13212",
                 external_id: "lin_ws_issues_live_13212_x11",
                 token: "lin_api_token_issues_live_13212",
                 webhook_secret: "whsec_issues_live_13212"
               },
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
  end
end
