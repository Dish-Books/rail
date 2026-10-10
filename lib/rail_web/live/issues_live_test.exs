defmodule RailWeb.IssuesLiveTest do
  use RailWeb.ConnCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Phoenix.LiveViewTest

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.LinearSync
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Users

  test "redirects an unauthenticated user to the sign-in page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/issues")
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

  test "the selected project sets the subtitle and switcher", %{conn: conn} do
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
               name: "Issues Project",
               github_repo: "example/issues-project",
               github_installation_id: 601,
               linear_team_key: "ISS",
               default_branch: "main",
               clone_path: "/tmp/issues-project",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    authed_conn = init_test_session(authed_conn, %{selected_project_id: project_id})

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")
    assert has_element?(view, "#selected-project-name", project_name)
    assert has_element?(view, "#issues-subtitle", "Linear issues in ISS (#{project_name})")

    view |> element("#project-switcher-button") |> render_click()
    view |> element("#project-option-all") |> render_click()

    assert_redirect(view, ~p"/project-selection?#{[project_id: "", return_to: "/issues"]}")
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

  test "renders an issue as a row with its identifier, title, priority, status, points, assignee and links", %{
    conn: conn,
    project: %Project{id: _project_id} = project
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_4",
        login: "issues_live_user_4",
        email: "issues_live_user_4@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

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

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Demo title"})

    {:ok, issue} =
      Issues.update_issue(issue, %{
        description: "Demo title\nDetailed explanation of the issue.",
        priority: :urgent,
        state: :in_progress,
        state_name: "In Progress",
        branch_name: "feat-demo-101",
        url: "https://linear.app/demo/issue/DEMO-101",
        estimate: 3,
        owner_user_id: user.id
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    assert has_element?(view, "#issue-card-#{issue.id}")
    assert has_element?(view, "#issue-card-#{issue.id} [data-qa='issue-identifier']", "DEMO-101")
    assert has_element?(view, "#issue-card-#{issue.id} [data-qa='issue-estimate']", "3")
    assert has_element?(view, "#issue-card-#{issue.id} [data-qa='issue-assignee'][title='issues_live_user_4']")
    refute has_element?(view, "#issue-card-#{issue.id} [data-qa='project-badge']")
    assert has_element?(view, "#issue-card-#{issue.id} [data-qa='issue-external-link']")
    assert has_element?(view, "#issue-card-#{issue.id} [data-qa='issue-title']", "Demo title")
    assert has_element?(view, "#issue-card-#{issue.id} [data-qa='issue-priority-badge']", "Urgent")
    assert has_element?(view, "#issue-card-#{issue.id} [data-qa='issue-status-badge']", "In Progress")

    # Starting work happens on the issue's page, not from the list.
    refute has_element?(view, "#issue-card-#{issue.id} button")

    # Clicking the row opens the issue's page.
    issue_path = ~p"/issues/#{issue.identifier}"
    assert {:error, {:live_redirect, %{to: ^issue_path}}} = view |> element("#issue-card-#{issue.id}") |> render_click()
  end

  test "filters by priority chips and updates chip counts", %{conn: conn, project: %Project{id: _project_id} = project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_5",
        login: "issues_live_user_5",
        email: "issues_live_user_5@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

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

    {:ok, issue_urgent} = Issues.create_issue(system_scope(), project, %{title: "Urgent issue"})

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

    {:ok, issue_high_1} = Issues.create_issue(system_scope(), project, %{title: "High issue 1"})

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

    {:ok, issue_high_2} = Issues.create_issue(system_scope(), project, %{title: "High issue 2"})

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

    {:ok, issue_low} = Issues.create_issue(system_scope(), project, %{title: "Low issue"})

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

  test "My issues shows only the issues the signed-in user owns", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_mine",
        login: "issues_live_user_mine",
        email: "issues_live_user_mine@example.com",
        admin: true
      })

    mine =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_mine_1",
        identifier: "MIN-1",
        title: "Mine",
        state: :backlog,
        owner_user_id: user.id
      })
      |> Repo.insert!()

    theirs =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_mine_2",
        identifier: "MIN-2",
        title: "Theirs",
        state: :backlog
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues")
    assert has_element?(view, "#issue-card-#{theirs.id}")

    view |> element("#issues-mine") |> render_click()
    assert_patched(view, ~p"/issues?mine=true")
    assert has_element?(view, "#issue-card-#{mine.id}")
    refute has_element?(view, "#issue-card-#{theirs.id}")
    assert has_element?(view, "#filter-priority-all", "All (1)")

    view |> element("#issues-mine") |> render_click()
    assert_patched(view, ~p"/issues")
    assert has_element?(view, "#issue-card-#{theirs.id}")
  end

  test "a user granted one project lists and syncs only that project's issues", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_granted",
        login: "issues_live_user_granted",
        email: "issues_live_user_granted@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})

    {:ok, %Project{id: other_id}} =
      Projects.create_project(system_scope(), %{
        name: "Hidden Project",
        github_repo: "example/hidden",
        github_installation_id: 556,
        linear_team_key: "HID",
        default_branch: "main",
        clone_path: "/tmp/hidden"
      })

    [here, hidden] =
      for {project_id, n} <- [{project.id, 1}, {other_id, 2}] do
        %Issue{}
        |> Issue.changeset(%{
          project_id: project_id,
          external_id: "lin_granted_#{n}",
          identifier: "GRA-#{n}",
          title: "Granted #{n}",
          state: :backlog
        })
        |> Repo.insert!()
      end

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues")
    assert has_element?(view, "#issue-card-#{here.id}")
    refute has_element?(view, "#issue-card-#{hidden.id}")
    assert has_element?(view, "#filter-priority-all", "All (1)")

    view |> element("#sync-issues-button") |> render_click()
    assert_enqueued(worker: LinearSync, args: %{project_id: project.id})
    refute_enqueued(worker: LinearSync, args: %{project_id: other_id})
  end

  test "toggles Show finished filter chip", %{conn: conn, project: %Project{id: _project_id} = project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_6",
        login: "issues_live_user_6",
        email: "issues_live_user_6@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

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

    {:ok, active_issue} = Issues.create_issue(system_scope(), project, %{title: "Active task"})

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

    {:ok, done_issue} = Issues.create_issue(system_scope(), project, %{title: "Done task"})

    {:ok, done_issue} =
      Issues.update_issue(done_issue, %{
        state: :done
      })

    duplicate_issue =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_issues_live_13208",
        identifier: "FIN-3",
        title: "Duplicate task",
        state: :duplicate,
        state_name: "Duplicate"
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    # By default, show_finished is false -> only active_issue visible
    assert has_element?(view, "#issue-card-#{active_issue.id}")
    refute has_element?(view, "#issue-card-#{done_issue.id}")
    refute has_element?(view, "#issue-card-#{duplicate_issue.id}")
    assert has_element?(view, "#filter-priority-all", "All (1)")

    # Toggle show finished on
    view |> element("#issues-show-finished") |> render_click()
    assert has_element?(view, "#issue-card-#{active_issue.id}")
    assert has_element?(view, "#issue-card-#{done_issue.id}")
    assert has_element?(view, "#issue-card-#{duplicate_issue.id}")
    assert has_element?(view, "#filter-priority-all", "All (3)")

    refute has_element?(view, "#task-link-#{done_issue.id}")

    # Toggle show finished off
    view |> element("#issues-show-finished") |> render_click()
    assert has_element?(view, "#issue-card-#{active_issue.id}")
    refute has_element?(view, "#issue-card-#{done_issue.id}")
  end

  test "an open list drops an issue as soon as Linear marks it Duplicate", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_dup",
        login: "issues_live_user_dup",
        email: "issues_live_user_dup@example.com",
        admin: true
      })

    {:ok, workspace} = Projects.get_linear_workspace(id: project.linear_workspace_id)

    issue =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_issues_live_dup",
        identifier: "FIN-4",
        title: "About to be a duplicate",
        state: :todo
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues")
    assert has_element?(view, "#issue-card-#{issue.id}")

    assert {:ok, _issue} =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Issue",
               "action" => "update",
               "data" => %{
                 "id" => "lin_issues_live_dup",
                 "teamId" => "lin_team_id",
                 "identifier" => "FIN-4",
                 "title" => "About to be a duplicate",
                 "state" => %{"id" => "st_dup", "name" => "Duplicate", "type" => "duplicate"}
               }
             })

    refute has_element?(view, "#issue-card-#{issue.id}")
  end

  test "a row names its status the way Linear does", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_label",
        login: "issues_live_user_label",
        email: "issues_live_user_label@example.com",
        admin: true
      })

    # Linear's Todo is an unstarted state, which Rail keeps as :backlog.
    issue =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_issues_live_label",
        identifier: "FIN-5",
        title: "Planned",
        state: :backlog,
        state_name: "Todo"
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues")

    assert has_element?(view, "#issue-card-#{issue.id} [data-qa='issue-status-badge'][title='Todo']", "Todo")
    refute has_element?(view, "#issue-card-#{issue.id} [data-qa='issue-status-badge']", "Backlog")
  end

  test "an issue with a task links to it from its row", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_7",
        login: "issues_live_user_7",
        email: "issues_live_user_7@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

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

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Bring local feature"})

    {:ok, issue} =
      Issues.update_issue(issue, %{
        state: :backlog
      })

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")
    refute has_element?(view, "#task-link-#{issue.id}")

    {:ok, task} = Pipeline.create_task(issue, :plan)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")
    assert has_element?(view, "#task-link-#{issue.id}[href='/tasks/#{task.id}']")
  end

  test "a child of a split that waits on a sibling reads Waiting on it, here and on its own page", %{
    conn: conn,
    project: project
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_split",
        login: "issues_live_user_split",
        email: "issues_live_user_split@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    for {identifier, title} <- [{"ISW-1", "Work on ISW-1"}, {"ISW-2", "Child ISW-2"}, {"ISW-3", "Child ISW-3"}] do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{"id" => "lin_#{identifier}", "identifier" => identifier, "title" => title}
            }
          }
        })
      end)
    end

    {:ok, parent_issue} = Issues.create_issue(system_scope(), project, %{title: "Work on ISW-1"})
    {:ok, parent} = Pipeline.create_task(parent_issue, :split)
    parent = Repo.preload(parent, [:issue, :project])

    [%{issue: first_issue}, %{issue: waiting_issue}] =
      for {{identifier, builds_on}, number} <- Enum.with_index([{"ISW-2", []}, {"ISW-3", [1]}], 1) do
        attrs = %{title: "Child #{identifier}", parent: parent_issue}
        {:ok, issue} = Issues.create_issue(system_scope(), project, attrs)

        part = %{
          number: number,
          builds_on: builds_on,
          builds_screen: false,
          plan: "## Implementation plan\n\nPart #{number}."
        }

        {:ok, child} = Pipeline.create_child_task(parent, issue, part)
        Repo.preload(child, [:issue, :project])
      end

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")
    assert has_element?(view, "#task-link-#{waiting_issue.id}", "Waiting on ISW-2")
    assert has_element?(view, "#task-link-#{first_issue.id}", "Queued for Engineer")

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues/ISW-3")
    assert has_element?(view, "#issue-task-link", "Waiting on ISW-2")
  end

  test "a row reads the latest run at the task's stage, not one it retried", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_retry",
        login: "issues_live_user_retry",
        email: "issues_live_user_retry@example.com",
        admin: true
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_retry_1", "identifier" => "RT-1", "title" => "Retry after failure"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Retry after failure"})
    {:ok, issue} = Issues.update_issue(issue, %{state: :backlog})
    {:ok, task} = Pipeline.create_task(issue, :review)
    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)
    now = DateTime.utc_now()

    {:ok, _failed} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: lead.id,
        status: :failed,
        error: "3 of 11 checks failed",
        started_at: DateTime.shift(now, hour: -2),
        completed_at: DateTime.shift(now, hour: -1)
      })

    {:ok, _retry} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: lead.id,
        status: :running,
        started_at: DateTime.shift(now, minute: -10)
      })

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues")

    assert has_element?(view, "#task-link-#{issue.id}", "Review running")
  end

  # The row's task is loaded without its issue, and the review file it reads is named for the issue.
  test "a task whose review is finished reads Ready to merge, as its own page does", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_ready",
        login: "issues_live_user_ready",
        email: "issues_live_user_ready@example.com",
        admin: true
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_ready_1", "identifier" => "RDY-1", "title" => "Finished review"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Finished review"})
    {:ok, issue} = Issues.update_issue(issue, %{state: :backlog})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: lead.id,
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.utc_now()
      })

    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _finished} = Pipeline.start_fix_round(run)

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues")

    assert has_element?(view, "#task-link-#{issue.id}", "Ready to merge")
  end

  test "sync_issues button triggers sync on current project or all projects", %{
    conn: conn,
    project: %Project{id: seeded_id}
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_10",
        login: "issues_live_user_10",
        email: "issues_live_user_10@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    # Async tests sync the seeded project and announce it to every Issues page, so
    # this one waits on a project nobody else syncs.
    {:ok, %Project{id: project_id}} =
      Projects.create_project(system_scope(), %{
        name: "Sync Project",
        github_repo: "example/sync",
        github_installation_id: 555,
        linear_team_key: "SYN",
        default_branch: "main",
        clone_path: "/tmp/sync"
      })

    # No Linear stub is queued: the click only queues the pull.
    assert {:ok, view, _html} = live(init_test_session(authed_conn, %{selected_project_id: project_id}), ~p"/issues")

    view |> element("#sync-issues-button") |> render_click()
    assert_enqueued(worker: LinearSync, args: %{project_id: project_id})
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
    send(view_all.pid, {:issues_synced, seeded_id})
    assert has_element?(view_all, "#sync-issues-button", "Sync Issues")

    # A comment changes nothing a row shows.
    send(view_all.pid, {:issue_comments_changed, "iss_any"})
    assert has_element?(view_all, "[data-qa='issue-title']", "Synced")
  end

  test "an issue Linear deletes leaves every open list and its priority count, with its task's link", %{
    conn: conn,
    project: project
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_removed",
        login: "issues_live_user_removed",
        email: "issues_live_user_removed@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)
    {:ok, workspace} = Projects.get_linear_workspace(id: project.linear_workspace_id)

    [doomed, kept] =
      for external_id <- ["lin_removed", "lin_still_here"] do
        %Issue{}
        |> Issue.changeset(%{
          project_id: project.id,
          external_id: external_id,
          identifier: external_id,
          title: external_id,
          priority: :high,
          state: :todo
        })
        |> Repo.insert!()
        |> Repo.preload(:project)
      end

    {:ok, _task} = Pipeline.create_task(doomed, :plan)

    assert {:ok, first_tab, _html} = live(authed_conn, ~p"/issues")
    assert {:ok, second_tab, _html} = live(authed_conn, ~p"/issues")
    assert has_element?(first_tab, "#task-link-#{doomed.id}")
    assert has_element?(first_tab, "#filter-priority-high", "High (2)")

    assert {:ok, %Issue{}} =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Issue",
               "action" => "remove",
               "data" => %{"id" => "lin_removed"}
             })

    for view <- [first_tab, second_tab] do
      refute has_element?(view, "#issue-card-#{doomed.id}")
      refute has_element?(view, "#task-link-#{doomed.id}")
      assert has_element?(view, "#issue-card-#{kept.id}")
      assert has_element?(view, "#filter-priority-high", "High (1)")
    end
  end

  test "an archive drops a done issue with no task from Show finished, and leaves one with a task", %{
    conn: conn,
    project: project
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_archived",
        login: "issues_live_user_archived",
        email: "issues_live_user_archived@example.com",
        admin: true
      })

    {:ok, workspace} = Projects.get_linear_workspace(id: project.linear_workspace_id)

    [untasked, tasked] =
      for external_id <- ["lin_archived_untasked", "lin_archived_tasked"] do
        %Issue{}
        |> Issue.changeset(%{
          project_id: project.id,
          external_id: external_id,
          identifier: external_id,
          title: external_id,
          state: :done
        })
        |> Repo.insert!()
        |> Repo.preload(:project)
      end

    {:ok, task} = Pipeline.create_task(tasked, :merged)

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues?finished=true")
    assert has_element?(view, "#issue-card-#{untasked.id}")

    for external_id <- ["lin_archived_untasked", "lin_archived_tasked"] do
      Issues.handle_linear_webhook(workspace, %{
        "type" => "Issue",
        "action" => "update",
        "data" => %{
          "id" => external_id,
          "teamId" => "lin_team_id",
          "identifier" => external_id,
          "title" => external_id,
          "state" => %{"id" => "st_done", "name" => "Done", "type" => "completed"},
          "archivedAt" => "2026-10-06T10:00:00.000Z"
        }
      })
    end

    refute has_element?(view, "#issue-card-#{untasked.id}")
    assert has_element?(view, "#issue-card-#{tasked.id}")
    assert has_element?(view, "#task-link-#{tasked.id}[href='/tasks/#{task.id}']")
  end

  test "a finished sync drops an issue Linear no longer lists, and keeps one with a task Linear moved", %{
    conn: conn
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_pruned",
        login: "issues_live_user_pruned",
        email: "issues_live_user_pruned@example.com",
        admin: true
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_pruned"}]}}})
    end)

    # A project nobody else syncs, since every Issues page hears every sync finish.
    {:ok, %Project{id: project_id} = sync_project} =
      Projects.create_project(system_scope(), %{
        name: "Pruned Project",
        github_repo: "example/pruned",
        github_installation_id: 556,
        linear_team_key: "PRU",
        default_branch: "main",
        clone_path: "/tmp/pruned",
        linear_workspace_id: "lw_test_seed"
      })

    [gone, moved] =
      for external_id <- ["lin_pruned_gone", "lin_pruned_moved"] do
        %Issue{}
        |> Issue.changeset(%{
          project_id: project_id,
          external_id: external_id,
          identifier: external_id,
          title: external_id,
          state: :todo
        })
        |> Repo.insert!()
        |> Map.put(:project, sync_project)
      end

    {:ok, task} = Pipeline.create_task(moved, :plan)

    assert {:ok, view, _html} =
             live(init_test_session(log_in_user(conn, user), %{selected_project_id: project_id}), ~p"/issues")

    view |> element("#sync-issues-button") |> render_click()
    assert [%Oban.Job{args: args}] = all_enqueued(worker: LinearSync, args: %{project_id: project_id})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issues" => %{
            "nodes" => [%{"id" => "lin_pruned_listed", "identifier" => "PRU-3", "title" => "Still listed"}],
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
          }
        }
      })
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{"issue" => %{"id" => "lin_pruned_moved", "team" => %{"id" => "lin_team_elsewhere"}}}
      })
    end)

    assert :ok = perform_job(LinearSync, args)

    assert has_element?(view, "#sync-issues-button", "Sync Issues")
    refute has_element?(view, "#issue-card-#{gone.id}")
    assert has_element?(view, "[data-qa='issue-title']", "Still listed")
    assert has_element?(view, "#issue-card-#{moved.id}")
    assert has_element?(view, "#task-link-#{moved.id}[href='/tasks/#{task.id}']")
  end

  test "searches issues from the URL and pages through them", %{conn: conn, project: %Project{id: project_id}} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_13",
        login: "issues_live_user_13",
        email: "issues_live_user_13@example.com",
        admin: true
      })

    authed_conn = log_in_user(conn, user)

    [oldest | _rest] =
      issues =
      Enum.map(1..51, fn n ->
        %Issue{}
        |> Issue.changeset(%{
          project_id: project_id,
          external_id: "lin_page_#{n}",
          identifier: "PAGE-#{n}",
          title: if(n == 1, do: "Fix login redirect", else: "Paged issue #{n}"),
          state: :backlog
        })
        |> Repo.insert!()
      end)

    newest = List.last(issues)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")

    assert has_element?(view, "#filter-priority-all", "All (51)")
    assert has_element?(view, "#issues-page-range", "Showing 1–50 of 51")
    assert has_element?(view, "#issue-card-#{newest.id}")
    refute has_element?(view, "#issue-card-#{oldest.id}")
    refute has_element?(view, "#issues-page-prev")

    view |> element("#issues-page-next") |> render_click()
    assert_patched(view, ~p"/issues?page=2")
    assert has_element?(view, "#issues-page-range", "Showing 51–51 of 51")
    assert has_element?(view, "#issue-card-#{oldest.id}")
    refute has_element?(view, "#issue-card-#{newest.id}")
    refute has_element?(view, "#issues-page-next")

    # Searching goes back to the first page of what matches.
    view |> element("#issues-search-form") |> render_change(%{"q" => "LOGIN"})
    assert_patched(view, ~p"/issues?q=LOGIN")
    assert has_element?(view, "#issues-page-range", "Showing 1–1 of 1")
    assert has_element?(view, "#issue-card-#{oldest.id}")
    assert has_element?(view, "#issues-search[value='LOGIN']")

    view |> element("#issues-search-form") |> render_submit(%{"q" => "PAGE-12"})
    assert_patched(view, ~p"/issues?q=PAGE-12")
    assert has_element?(view, "[data-qa='issue-identifier']", "PAGE-12")
    refute has_element?(view, "#issue-card-#{oldest.id}")

    view |> element("#issues-search-form") |> render_change(%{"q" => "nothing like this"})
    assert has_element?(view, "[data-qa='empty-state-title']", "No issues match")
    refute has_element?(view, "#issues-pagination")

    # The URL alone is enough to land on a page; one past the end shows the last,
    # and a bad page number is page one.
    assert {:ok, linked, _html} = live(authed_conn, ~p"/issues?page=2")
    assert has_element?(linked, "#issue-card-#{oldest.id}")

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
               name: "With Key Project",
               github_repo: "example/with-key",
               github_installation_id: 801,
               linear_team_key: "KEY",
               default_branch: "main",
               clone_path: "/tmp/with-key",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    assert {:ok, view, _html} = live(init_test_session(authed_conn, %{selected_project_id: p_id}), ~p"/issues")
    assert has_element?(view, "#issues-subtitle", "Linear issues in KEY (#{p_name})")

    # Nonexistent project ID
    assert {:ok, view_bad, _html} =
             live(init_test_session(authed_conn, %{selected_project_id: "prj_nonexistent"}), ~p"/issues")

    assert has_element?(view_bad, "#issues-subtitle", "Linear issues across all projects")
  end
end
