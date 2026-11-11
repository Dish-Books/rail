defmodule RailWeb.IssuesLiveTest do
  use RailWeb.ConnCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Rail.Pipeline.Utils.BuildTask

  alias Phoenix.LiveView.Socket
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Issues.Workers.LinearSync
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users
  alias Rail.Users.Schemas.User
  alias Rail.Workflows.Schemas.Workflow
  alias Rail.Workflows.Schemas.WorkflowDefinition
  alias RailWeb.IssuesLive

  setup do
    # A role's prompt is read from the project's clone, which another test may have made, so reading it here
    # would spawn git: these see no prompt file on the default branch, as when there is no clone. A task Linear
    # deletes takes its worktree and branch in that clone with it.
    stub(Rail.Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)
    stub(Rail.Git, :remove_worktree, fn _clone_path, _worktree_path -> :ok end)
    stub(Rail.Git, :delete_branch, fn _clone_path, _branch -> :ok end)
    # The seeded project is on Linear, so the page asks it for cycles and blockers; these tests are about neither.
    stub(Issues, :get_cycles, fn _project -> {:ok, %{cycles: [], statuses: []}} end)
    stub(Issues, :get_blockers, fn _issues -> %{} end)

    :ok
  end

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
    assert has_element?(view, "#issues-subtitle", "Issues across all projects")
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
               key: "ISSILS",
               default_branch: "main",
               clone_path: "/tmp/issues-project",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    authed_conn = init_test_session(authed_conn, %{selected_project_id: project_id})

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")
    assert has_element?(view, "#selected-project-name", project_name)
    assert has_element?(view, "#issues-subtitle", "Linear issues in ISSILS (#{project_name})")

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
    refute has_element?(view, "#issue-card-#{issue.id} button", "Plan")

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
        key: "HIDILS",
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

  test "an issue a workflow opened is marked with the workflow and unassigned, for anyone who can see it", %{
    conn: conn,
    project: project
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_workflow",
        login: "issues_live_user_workflow",
        email: "issues_live_user_workflow@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})

    workflow =
      Repo.insert!(%Workflow{
        project_id: project.id,
        path: ".rail/workflows/flaky-test-sweep.yml",
        definition: %WorkflowDefinition{
          name: "Flaky test sweep",
          schedule: "0 9 * * 1",
          instructions: "Sweep the flaky tests."
        },
        next_run_at: ~U[2026-10-12 09:00:00Z]
      })

    [opened, filed] =
      for {workflow_id, n} <- [{workflow.id, 1}, {nil, 2}] do
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: project.id,
          workflow_id: workflow_id,
          external_id: "lin_workflow_card_#{n}",
          identifier: "WFC-#{n}",
          title: "Card #{n}",
          state: :triage
        })
        |> Repo.insert!()
      end

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues")

    assert has_element?(view, ~s(#issue-workflow-#{opened.id}[title="Opened by the Flaky test sweep workflow"]))
    assert has_element?(view, "#issue-card-#{opened.id} .sr-only", "From the Flaky test sweep workflow:")
    assert has_element?(view, "#issue-card-#{opened.id} [data-qa=issue-unassigned]")
    refute has_element?(view, "#issue-workflow-#{filed.id}")

    # A sync that renames the workflow shows on the open list.
    workflow
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_embed(:definition, %{name: "Flake sweep"})
    |> Repo.update!()

    Phoenix.PubSub.broadcast(Rail.PubSub, "workflows", {:workflows_changed, project.id})
    assert has_element?(view, ~s(#issue-workflow-#{opened.id}[title="Opened by the Flake sweep workflow"]))
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
      |> Issue.tracker_changeset(%{
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
      |> Issue.tracker_changeset(%{
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
      |> Issue.tracker_changeset(%{
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

  test "a task whose custom stage saved its file and waits on Approve reads Review and the stage's name", %{
    conn: conn,
    project: project
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_custom",
        login: "issues_live_user_custom",
        email: "issues_live_user_custom@example.com",
        admin: true
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_il_custom", "identifier" => "ILC-1", "title" => "Dependency updates"}
          }
        }
      })
    end)

    stages = [
      %IssueStage{stage: :plan},
      %IssueStage{stage: :engineer},
      %IssueStage{stage: :custom, name: "License check", prompt: "Check each license."},
      %IssueStage{stage: :review}
    ]

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Dependency updates", stages: stages})
    {:ok, issue} = Issues.update_issue(issue, %{state: :in_progress})
    {:ok, task} = Pipeline.create_task(issue, {:custom, "License check"})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    {:ok, role} = Roles.get_custom_stage_role(project.id, "License check")

    {:ok, _run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :finished, started_at: DateTime.utc_now()})

    {:ok, _saved} = Pipeline.save_stage_output(task, %{markdown: "All MIT."})

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues")
    assert has_element?(view, "#task-link-#{issue.id}", "Review License check")
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

        {:ok, child} =
          issue.project
          |> build_task(issue, %{stage: :engineer, split_position: number, builds_on: builds_on})
          |> Ecto.Changeset.put_change(:parent_task_id, parent.id)
          |> Repo.insert()

        Repo.preload(child, [:issue, :project])
      end

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")
    assert has_element?(view, "#task-link-#{waiting_issue.id}", "Waiting on ISW-2")
    assert has_element?(view, "#task-link-#{first_issue.id}", "Queued for Implement")

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

  test "a task whose Review round waits on a person reads Review", %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_review_waiting",
        login: "issues_live_user_review_waiting",
        email: "issues_live_user_review_waiting@example.com",
        admin: true
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_review_waiting_1", "identifier" => "RVW-1", "title" => "Findings to rule"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Findings to rule"})
    {:ok, issue} = Issues.update_issue(issue, %{state: :backlog})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, _waiting} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: lead.id,
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.utc_now()
      })

    {:ok, _pass} = Pipeline.save_review(task)

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues")

    assert has_element?(view, "#task-link-#{issue.id}", ~r/^\s*Review\s*$/)
  end

  # The row's task is loaded without its issue, and the review file it reads is named for the issue.
  test "a task whose review is finished reads Ready to finalize, as its own page does", %{conn: conn, project: project} do
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
    {:ok, _finished} = Pipeline.start_fix_round(system_scope(), run)

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues")

    assert has_element?(view, "#task-link-#{issue.id}", "Ready to finalize")
  end

  test "a GitHub project's issues are titled by its tracker and key", %{conn: conn, github_project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_gh",
        login: "issues_live_gh",
        email: "ilg@example.com",
        admin: true
      })

    conn = conn |> log_in_user(user) |> init_test_session(%{selected_project_id: project.id})

    github_issue(project, %{
      number: 5,
      identifier: "tgh#5",
      title: "From GitHub",
      url: "https://github.com/example/test-gh/issues/5"
    })

    assert {:ok, view, _html} = live(conn, ~p"/issues")
    assert has_element?(view, "#issues-subtitle", "GitHub issues in tgh (Test GitHub Project)")
    assert has_element?(view, "[data-qa='issue-external-link'][title='Open issue in GitHub']")
  end

  test "Sync Issues pulls only the projects kept outside Rail, and is gone when Rail keeps them all", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issues_live_local_sync",
        login: "issues_live_local_sync",
        email: "issues_live_local_sync@example.com"
      })

    n = System.unique_integer([:positive])

    {:ok, %Project{id: linear_id}} =
      Projects.create_project(system_scope(), %{
        name: "Kept in Linear",
        github_repo: "example/lin-#{n}",
        github_installation_id: 557,
        key: "LIN#{n}",
        default_branch: "main",
        clone_path: "/tmp/lin"
      })

    {:ok, %Project{id: local_id}} =
      Projects.create_project(system_scope(), %{
        name: "Kept in Rail",
        github_repo: "example/own-#{n}",
        github_installation_id: 557,
        tracker: :local,
        key: "OWN#{n}",
        default_branch: "main",
        clone_path: "/tmp/own"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [linear_id, local_id]})
    authed_conn = log_in_user(conn, user)

    assert {:ok, view, _html} = live(authed_conn, ~p"/issues")
    view |> element("#sync-issues-button") |> render_click()
    assert_enqueued(worker: LinearSync, args: %{project_id: linear_id})
    assert has_element?(view, "#sync-issues-button[disabled]", "Syncing...")

    send(view.pid, {:issues_synced, linear_id})
    assert has_element?(view, "#sync-issues-button", "Sync Issues")

    assert {:ok, local_view, _html} =
             live(init_test_session(authed_conn, %{selected_project_id: local_id}), ~p"/issues")

    refute has_element?(local_view, "#sync-issues-button")

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [local_id]})
    assert {:ok, only_local, _html} = live(log_in_user(conn, user), ~p"/issues")
    refute has_element?(only_local, "#sync-issues-button")
  end

  test "sync_issues button triggers sync on current project or all projects", %{
    conn: conn,
    project: %Project{id: seeded_id},
    github_project: %Project{id: seeded_github_id}
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
        key: "SYNILS",
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
    send(view_all.pid, {:issues_synced, seeded_github_id})
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
        key: "PRU",
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
               key: "KEY",
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

    assert has_element?(view_bad, "#issues-subtitle", "Issues across all projects")
  end

  describe "changing a status" do
    setup %{conn: conn, project: project} do
      {:ok, viewer} =
        Users.register_oauth_user(%{
          github_id: "gh_status_viewer",
          login: "status_viewer",
          email: "status_viewer@example.com",
          admin: true
        })

      statuses = [
        %{id: "st_review", name: "In Review", state: :in_review},
        %{id: "st_done", name: "Done", state: :done}
      ]

      stub(Issues, :get_statuses, fn _scope, _project -> {:ok, statuses} end)

      issue =
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: project.id,
          external_id: "lin_STS-1",
          identifier: "STS-1",
          title: "To move",
          state: :in_progress,
          state_name: "In Progress"
        })
        |> Repo.insert!()

      answered = fn state, completed_at ->
        fn conn ->
          Req.Test.json(conn, %{
            "data" => %{
              "issueUpdate" => %{
                "success" => true,
                "issue" => %{"state" => state, "completedAt" => completed_at, "updatedAt" => "2026-11-01T10:00:00.000Z"}
              }
            }
          })
        end
      end

      %{conn: log_in_user(conn, viewer), issue: issue, answered: answered}
    end

    test "a pick in the plain list shows in a second view with no reload, and a dimmed copy offers no menu", %{
      conn: conn,
      issue: %{id: id},
      answered: answered
    } do
      {:ok, view, _html} = live(conn, ~p"/issues")
      {:ok, other_view, _html} = live(conn, ~p"/issues")
      Req.Test.allow(Rail.Linear, self(), view.pid)

      view |> element("#status-picker-#{id}-trigger") |> render_click()
      render_async(view)

      Req.Test.expect(Rail.Linear, answered.(%{"name" => "In Review", "type" => "started"}, nil))
      view |> element("#status-picker-#{id}-status-st_review") |> render_click()

      assert has_element?(view, "#issue-card-#{id} [data-qa='issue-status-badge'][title='In Review']")
      assert has_element?(other_view, "#issue-card-#{id} [data-qa='issue-status-badge'][title='In Review']")
      assert has_element?(other_view, "#issue-card-#{id} .text-emerald-500")
    end

    test "Done leaves the list while Show finished is off, and stays with it on", %{
      conn: conn,
      issue: %{id: id},
      answered: answered
    } do
      {:ok, view, _html} = live(conn, ~p"/issues")
      {:ok, finished_view, _html} = live(conn, ~p"/issues?finished=true")
      Req.Test.allow(Rail.Linear, self(), view.pid)

      view |> element("#status-picker-#{id}-trigger") |> render_click()
      render_async(view)

      Req.Test.expect(
        Rail.Linear,
        answered.(%{"name" => "Done", "type" => "completed"}, "2026-11-01T10:00:00.000Z")
      )

      view |> element("#status-picker-#{id}-status-st_done") |> render_click()

      refute has_element?(view, "#issue-card-#{id}")
      assert has_element?(finished_view, "#issue-card-#{id} [data-qa='issue-status-badge'][title='Done']")
    end

    test "a dimmed copy of a parent keeps its plain mark", %{conn: conn, project: project} do
      insert = fn identifier, attrs ->
        %Issue{}
        |> Issue.tracker_changeset(
          Map.merge(
            %{
              project_id: project.id,
              external_id: "lin_#{identifier}",
              identifier: identifier,
              title: "Title #{identifier}",
              state: :in_progress
            },
            attrs
          )
        )
        |> Repo.insert!()
      end

      %{id: parent_id} = insert.("STS-2", %{state: :done, state_name: "Done"})
      %{id: child_id} = insert.("STS-3", %{parent_external_id: "lin_STS-2"})

      {:ok, view, _html} = live(conn, ~p"/issues")

      dimmed = "#issue-card-#{parent_id}-above-#{child_id}"
      assert has_element?(view, "#{dimmed} [data-qa='issue-status-badge'][title='Done']")
      refute has_element?(view, "#{dimmed} button[data-qa='issue-status-badge']")
      refute has_element?(view, "#status-picker-#{parent_id}-trigger")
      assert has_element?(view, "#status-picker-#{child_id}-trigger")
    end
  end

  describe "remembered filters" do
    setup %{conn: conn} do
      {:ok, user} =
        Users.register_oauth_user(%{
          github_id: "gh_issues_live_saved",
          login: "issues_live_saved",
          email: "issues_live_saved@example.com",
          admin: true
        })

      %{conn: log_in_user(conn, user), user: user}
    end

    test "a bare /issues opens on the filters last set, without the search, and a teammate's page keeps its own", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/issues")

      view |> element("#filter-priority-high") |> render_click()
      view |> element("#issues-show-finished") |> render_click()
      view |> element("#issues-search-form") |> render_change(%{"q" => "login"})
      assert_patched(view, ~p"/issues?#{[q: "login", priority: "high", finished: true]}")

      assert %User{issues_filters: %{"priority" => "high", "finished" => "true"} = saved} =
               Repo.reload!(user)

      assert map_size(saved) == 2

      assert {:error, {:live_redirect, %{to: "/issues?priority=high&finished=true"}}} = live(conn, ~p"/issues")

      # Back from the nav within the same visit reads what was saved since the page opened.
      {:ok, view, _html} = live(conn, ~p"/issues?priority=high&finished=true")
      view |> element("#filter-priority-urgent") |> render_click()
      assert {:error, {:live_redirect, %{to: "/issues?priority=urgent&finished=true"}}} = live(conn, ~p"/issues")

      {:ok, teammate} =
        Users.register_oauth_user(%{
          github_id: "gh_issues_live_teammate",
          login: "issues_live_teammate",
          email: "issues_live_teammate@example.com",
          admin: true
        })

      assert {:ok, _view, _html} = live(log_in_user(build_conn(), teammate), ~p"/issues")
    end

    test "a link's filters apply without saving, and clearing every filter keeps /issues bare", %{
      conn: conn,
      user: user
    } do
      {:ok, _user} = Users.set_issues_filters(Scope.for_user(user), %{"mine" => "true"})

      {:ok, view, _html} = live(conn, ~p"/issues?priority=low")
      assert has_element?(view, "#filter-priority-low.bg-blue-600")
      assert %User{issues_filters: %{"mine" => "true"}} = Repo.reload!(user)

      # A search or page in the URL comes along when the saved filters are applied.
      assert {:error, {:live_redirect, %{to: "/issues?q=crash&mine=true"}}} = live(conn, ~p"/issues?q=crash")

      {:ok, view, _html} = live(conn, ~p"/issues?mine=true")
      view |> element("#issues-mine") |> render_click()
      assert_patched(view, ~p"/issues")
      cleared = %{}
      assert %User{issues_filters: ^cleared} = Repo.reload!(user)

      assert {:ok, _view, _html} = live(conn, ~p"/issues")
    end

    test "Back from the first filter shows the bare list, keeps what was saved, and a fresh visit still restores it", %{
      conn: conn,
      user: user,
      project: project
    } do
      low =
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: project.id,
          external_id: "lin_back_low",
          identifier: "BCK-1",
          title: "A low one",
          state: :todo,
          priority: :low
        })
        |> Repo.insert!()

      {:ok, view, _html} = live(conn, ~p"/issues")
      view |> element("#filter-priority-high") |> render_click()
      assert_patched(view, ~p"/issues?priority=high")
      refute has_element?(view, "#issue-card-#{low.id}")

      render_patch(view, ~p"/issues")
      assert has_element?(view, "#issue-card-#{low.id}")
      refute has_element?(view, "#filter-priority-high.bg-blue-600")
      assert %User{issues_filters: %{"priority" => "high"}} = Repo.reload!(user)

      assert {:error, {:live_redirect, %{to: "/issues?priority=high"}}} = live(conn, ~p"/issues")
    end

    test "where no chip shows, a filter click keeps the saved cycle view and owner, and My issues replaces the owner", %{
      conn: conn,
      user: %User{id: user_id} = user,
      github_project: github_project
    } do
      {:ok, _user} = Users.set_issues_filters(Scope.for_user(user), %{"cycle" => "current", "owner" => user_id})
      conn = init_test_session(conn, %{selected_project_id: github_project.id})

      {:error, {:live_redirect, %{to: restored}}} = live(conn, ~p"/issues")
      {:ok, view, _html} = live(conn, restored)
      refute has_element?(view, "#cycle-toggle")

      view |> element("#issues-show-finished") |> render_click()
      assert_patched(view, ~p"/issues?finished=true")

      finished = %{"cycle" => "current", "owner" => user_id, "finished" => "true"}
      assert %User{issues_filters: ^finished} = Repo.reload!(user)

      view |> element("#issues-mine") |> render_click()
      assert_patched(view, ~p"/issues?mine=true&finished=true")

      mine = %{"cycle" => "current", "mine" => "true", "finished" => "true"}
      assert %User{issues_filters: ^mine} = Repo.reload!(user)
    end
  end

  describe "cycle view" do
    setup %{conn: conn, project: project} do
      people =
        for name <- ["Ana", "Bo"] do
          {:ok, user} =
            Users.register_oauth_user(%{
              github_id: "gh_cycle_#{name}",
              login: "cycle_#{name}",
              name: name,
              email: "cycle_#{name}@example.com"
            })

          user
        end

      {:ok, viewer} =
        Users.register_oauth_user(%{
          github_id: "gh_cycle_viewer",
          login: "cycle_viewer",
          email: "cycle_viewer@example.com",
          admin: true
        })

      cycle = fn id, number, status, current ->
        %{
          id: id,
          number: number,
          name: nil,
          starts_on: ~D[2026-10-26],
          ends_on: ~D[2026-11-08],
          status: status,
          current: current,
          scope_history: [5.0, 6.0],
          started_history: [1.0, 3.0],
          completed_history: [+0.0, 1.0],
          default_estimate: 1
        }
      end

      cycles = %{
        cycles: [
          cycle.("cyc_11", 11, :ended, false),
          cycle.("cyc_12", 12, :running, true),
          cycle.("cyc_13", 13, :upcoming, false)
        ],
        statuses: [
          %{name: "Backlog", type: "backlog", position: 0},
          %{name: "Ready for Dev", type: "unstarted", position: 1},
          %{name: "In Progress", type: "started", position: 2},
          %{name: "In Review", type: "started", position: 3},
          %{name: "Done", type: "completed", position: 4}
        ]
      }

      stub(Issues, :get_cycles, fn _project -> {:ok, cycles} end)

      insert = fn identifier, attrs ->
        %Issue{}
        |> Issue.tracker_changeset(
          Map.merge(
            %{
              project_id: project.id,
              external_id: "lin_#{identifier}",
              identifier: identifier,
              title: "Title #{identifier}",
              state: :backlog
            },
            attrs
          )
        )
        |> Repo.insert!()
      end

      [ana, bo] = people

      # A task at `stage` with its role's run in the state `attrs` say.
      open_task = fn issue, stage, attrs ->
        {:ok, task} = issue |> Repo.preload(:project) |> Pipeline.create_task(stage)
        {:ok, role} = Roles.get_role(project_id: project.id, stage: Task.role_stage(stage))
        defaults = %{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()}
        {:ok, run} = Pipeline.create_run(Map.merge(defaults, attrs))
        {task, run}
      end

      %{
        conn: conn |> log_in_user(viewer) |> init_test_session(%{selected_project_id: project.id}),
        viewer: viewer,
        ana: ana,
        bo: bo,
        cycles: cycles,
        insert: insert,
        open_task: open_task,
        reviewing:
          insert.("CYC-1", %{
            state: :in_progress,
            state_name: "In Review",
            cycle_external_id: "cyc_12",
            owner_user_id: ana.id,
            estimate: 3,
            priority: :high
          }),
        working:
          insert.("CYC-2", %{
            state: :in_progress,
            state_name: "In Progress",
            cycle_external_id: "cyc_12",
            owner_user_id: bo.id,
            estimate: 2
          }),
        ready:
          insert.("CYC-3", %{
            state: :backlog,
            state_name: "Ready for Dev",
            cycle_external_id: "cyc_12",
            owner_user_id: ana.id
          }),
        outside: insert.("CYC-4", %{state: :backlog, state_name: "Backlog"})
      }
    end

    test "the chip opens the current cycle grouped by Linear's statuses beside its figures, and turns back off", %{
      conn: conn,
      viewer: viewer,
      reviewing: reviewing,
      working: working,
      ready: ready,
      outside: outside
    } do
      {:ok, view, _html} = live(conn, ~p"/issues")
      render_async(view)

      assert has_element?(view, "#cycle-toggle[aria-pressed='false']", "Current cycle")
      view |> element("#cycle-toggle") |> render_click()
      assert_patched(view, ~p"/issues?cycle=12")
      assert %User{issues_filters: %{"cycle" => "current"}} = Repo.reload!(viewer)

      assert has_element?(view, "#cycle-toggle[aria-pressed='true']", "Cycle 12")
      assert has_element?(view, "#cycle-issues section[aria-label='In Review']", "1 issue")
      assert has_element?(view, "#cycle-issues section[aria-label='In Review'] #issue-card-#{reviewing.id}")
      assert has_element?(view, "#issue-card-#{reviewing.id} .text-emerald-500")
      assert has_element?(view, "#cycle-issues section[aria-label='In Progress'] #issue-card-#{working.id}")
      assert has_element?(view, "#cycle-issues section[aria-label='Ready for Dev'] #issue-card-#{ready.id}")
      assert has_element?(view, "#cycle-issues section[aria-label='Ready for Dev'] > div:first-child .pi-circle-dashed")
      assert has_element?(view, "#issue-card-#{ready.id} .pi-circle-dashed")
      refute has_element?(view, "#issue-card-#{outside.id}")
      refute has_element?(view, "#issues-pagination")

      html = render(view)
      [_before, after_review] = String.split(html, ~s(aria-label="In Review"), parts: 2)
      assert after_review =~ ~s(aria-label="In Progress")
      [_before, after_progress] = String.split(after_review, ~s(aria-label="In Progress"), parts: 2)
      assert after_progress =~ ~s(aria-label="Ready for Dev")

      # Three, two and the team's default of one.
      assert has_element?(view, "#cycle-panel[aria-label='Cycle 12']")
      refute has_element?(view, "#cycle-edit-dates")
      assert has_element?(view, "#cycle-scope", "6")
      assert has_element?(view, "#cycle-started", "5")
      assert has_element?(view, "#cycle-scope", "+20%")
      refute render(view) =~ "since Oct 26"
      assert has_element?(view, "#cycle-chart")
      assert has_element?(view, "#filter-priority-all", "All (3)")
      assert has_element?(view, "#filter-priority-high", "High (1)")

      view |> element("#cycle-toggle") |> render_click()
      assert_patched(view, ~p"/issues")
      assert has_element?(view, "#issue-card-#{outside.id}")
      assert %User{issues_filters: %{}} = Repo.reload!(viewer)
    end

    test "a pick moves the row between groups and changes both groups and the figures, in a second view too", %{
      conn: conn,
      working: %{id: working_id},
      ready: %{id: ready_id}
    } do
      statuses = [
        %{id: "st_ready", name: "Ready for Dev", state: :backlog},
        %{id: "st_started", name: "In Progress", state: :in_progress},
        %{id: "st_review", name: "In Review", state: :in_review},
        %{id: "st_done", name: "Done", state: :done}
      ]

      stub(Issues, :get_statuses, fn _scope, _project -> {:ok, statuses} end)

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      {:ok, other_view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)
      render_async(other_view)
      Req.Test.allow(Rail.Linear, self(), view.pid)

      answered = fn state, completed_at ->
        fn conn ->
          Req.Test.json(conn, %{
            "data" => %{
              "issueUpdate" => %{
                "success" => true,
                "issue" => %{"state" => state, "completedAt" => completed_at, "updatedAt" => "2026-11-01T10:00:00.000Z"}
              }
            }
          })
        end
      end

      assert has_element?(view, "#cycle-issues section[aria-label='In Review']", "1 issue")
      assert has_element?(view, "#cycle-started", "5")

      view |> element("#status-picker-#{working_id}-trigger") |> render_click()
      render_async(view)

      Req.Test.expect(Rail.Linear, answered.(%{"name" => "In Review", "type" => "started"}, nil))
      view |> element("#status-picker-#{working_id}-status-st_review") |> render_click()

      for shown <- [view, other_view] do
        assert has_element?(shown, "#cycle-issues section[aria-label='In Review'] #issue-card-#{working_id}")
        assert has_element?(shown, "#cycle-issues section[aria-label='In Review']", "2 issues")
        assert has_element?(shown, "#cycle-issues section[aria-label='In Review'] [title='5 points']")
        refute has_element?(shown, "#cycle-issues section[aria-label='In Progress']")
      end

      # Starting an issue raises Started, in the open page and the other one.
      view |> element("#status-picker-#{ready_id}-trigger") |> render_click()
      render_async(view)

      Req.Test.expect(Rail.Linear, answered.(%{"name" => "In Progress", "type" => "started"}, nil))
      view |> element("#status-picker-#{ready_id}-status-st_started") |> render_click()

      assert has_element?(view, "#cycle-started", "6")
      assert has_element?(other_view, "#cycle-started", "6")
      assert has_element?(other_view, "#cycle-issues section[aria-label='In Progress'] #issue-card-#{ready_id}")

      # Reaching Done raises Completed.
      refute has_element?(other_view, "#cycle-completed", "2")

      Req.Test.expect(
        Rail.Linear,
        answered.(%{"name" => "Done", "type" => "completed"}, "2026-11-01T10:00:00.000Z")
      )

      view |> element("#status-picker-#{working_id}-trigger") |> render_click()
      view |> element("#status-picker-#{working_id}-status-st_done") |> render_click()

      assert has_element?(other_view, "#cycle-completed", "2")
    end

    test "picking an owner narrows the list while the figures stay the cycle's, and nothing matching names the cycle", %{
      conn: conn,
      ana: ana,
      bo: bo,
      reviewing: reviewing,
      working: working
    } do
      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12&mine=true")
      render_async(view)

      view |> element("#cycle-owner-#{bo.id}") |> render_click()
      assert_patched(view, ~p"/issues?cycle=12&owner=#{bo.id}")
      assert has_element?(view, "#issue-card-#{working.id}")
      refute has_element?(view, "#issue-card-#{reviewing.id}")
      assert has_element?(view, "#cycle-owner-#{bo.id}[aria-pressed='true']", "Clear filter")
      assert has_element?(view, "#cycle-scope", "6")
      refute has_element?(view, "#cycle-owner-chip")

      view |> element("#filter-priority-high") |> render_click()
      assert_patched(view, ~p"/issues?priority=high&cycle=12&owner=#{bo.id}")
      assert has_element?(view, "[data-qa='empty-state-title']", "No issues in Cycle 12")
      refute has_element?(view, "#issues-list")
      assert has_element?(view, "#cycle-panel")

      view |> element("#cycle-owner-#{bo.id}") |> render_click()
      assert_patched(view, ~p"/issues?priority=high&cycle=12")
      assert has_element?(view, "#issue-card-#{reviewing.id}")

      # My issues and an owner exclude each other.
      view |> element("#cycle-owner-#{ana.id}") |> render_click()
      view |> element("#issues-mine") |> render_click()
      assert_patched(view, ~p"/issues?priority=high&mine=true&cycle=12")

      # An owner with nothing in the cycle is no filter at all, and a link naming both keeps My issues.
      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12&owner=usr_nobody")
      render_async(view)
      assert has_element?(view, "#issue-card-#{working.id}")
      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12&mine=true&owner=#{bo.id}")
      render_async(view)
      refute has_element?(view, "#issue-card-#{working.id}")
    end

    test "the arrows step through cycles and stop at either end, and a search keeps narrowing inside one", %{
      conn: conn,
      insert: insert,
      viewer: viewer,
      reviewing: reviewing
    } do
      ended = insert.("CYC-5", %{state: :done, state_name: "Done", cycle_external_id: "cyc_11"})

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)

      view |> element("#cycle-previous") |> render_click()
      assert_patched(view, ~p"/issues?cycle=11")
      assert has_element?(view, "#cycle-toggle", "Cycle 11")
      assert has_element?(view, "#cycle-previous[disabled]")
      assert has_element?(view, "[data-qa='empty-state-title']", "No issues in Cycle 11")
      assert %User{issues_filters: %{}} = Repo.reload!(viewer)

      view |> element("#issues-show-finished") |> render_click()
      assert has_element?(view, "#cycle-issues section[aria-label='Done'] #issue-card-#{ended.id}")

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=13")
      render_async(view)
      assert has_element?(view, "#cycle-next[disabled]")
      assert has_element?(view, "#cycle-panel", "Planned so far")

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12&q=CYC-1")
      render_async(view)
      assert has_element?(view, "#issue-card-#{reviewing.id}")
      assert has_element?(view, "#filter-priority-all", "All (1)")
    end

    test "a cycle moving its only issue out shows the empty state, not the whole list", %{
      conn: conn,
      project: project,
      insert: insert,
      outside: outside
    } do
      only = insert.("CYC-6", %{state: :backlog, state_name: "Backlog", cycle_external_id: "cyc_13"})
      {:ok, workspace} = Projects.get_linear_workspace(id: project.linear_workspace_id)

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=13")
      render_async(view)
      assert has_element?(view, "#issue-card-#{only.id}")

      assert {:ok, _issue} =
               Issues.handle_linear_webhook(workspace, %{
                 "type" => "Issue",
                 "action" => "update",
                 "data" => %{
                   "id" => only.external_id,
                   "teamId" => "lin_team_id",
                   "identifier" => "CYC-6",
                   "title" => "Title CYC-6",
                   "state" => %{"name" => "Backlog", "type" => "backlog"}
                 },
                 "updatedFrom" => %{"cycleId" => "cyc_13"}
               })

      refute has_element?(view, "#issue-card-#{only.id}")
      refute has_element?(view, "#issue-card-#{outside.id}")
      assert has_element?(view, "[data-qa='empty-state-title']", "No issues in Cycle 13")

      # Into the cycle again, with its figures following.
      assert {:ok, _issue} =
               Issues.handle_linear_webhook(workspace, %{
                 "type" => "Issue",
                 "action" => "update",
                 "data" => %{
                   "id" => only.external_id,
                   "teamId" => "lin_team_id",
                   "identifier" => "CYC-6",
                   "title" => "Title CYC-6",
                   "cycleId" => "cyc_13",
                   "estimate" => 4,
                   "state" => %{"name" => "Backlog", "type" => "backlog"}
                 }
               })

      assert has_element?(view, "#issue-card-#{only.id}")
      assert has_element?(view, "#cycle-scope", "4")
    end

    test "an issue finishing moves today's point on the Completed line in every open tab", %{
      conn: conn,
      project: project,
      cycles: cycles,
      reviewing: reviewing
    } do
      today = Date.utc_today()

      running =
        cycles.cycles
        |> Enum.find(& &1.current)
        |> Map.merge(%{starts_on: Date.add(today, -1), ends_on: Date.add(today, 12)})

      stub(Issues, :get_cycles, fn _project -> {:ok, %{cycles | cycles: [running]}} end)
      {:ok, workspace} = Projects.get_linear_workspace(id: project.linear_workspace_id)

      tabs =
        for _tab <- 1..2 do
          {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
          render_async(view)
          assert has_element?(view, "path[stroke='#6366f1'][d='M4.0,128.0 L28.0,128.0']")
          view
        end

      assert {:ok, _issue} =
               Issues.handle_linear_webhook(workspace, %{
                 "type" => "Issue",
                 "action" => "update",
                 "data" => %{
                   "id" => reviewing.external_id,
                   "teamId" => "lin_team_id",
                   "identifier" => "CYC-1",
                   "title" => "Title CYC-1",
                   "cycleId" => "cyc_12",
                   "estimate" => 3,
                   "state" => %{"name" => "Done", "type" => "completed"}
                 }
               })

      for view <- tabs do
        assert has_element?(view, "#cycle-completed", "3")
        assert has_element?(view, "path[stroke='#6366f1'][d='M4.0,128.0 L28.0,73.5']")
        assert has_element?(view, "rect[data-day='1'][data-completed='3']")
      end
    end

    test "a saved cycle view opens on the current cycle by its number", %{conn: conn, viewer: viewer} do
      {:ok, _viewer} = Users.set_issues_filters(Scope.for_user(viewer), %{"cycle" => "current"})

      assert {:error, {:live_redirect, %{to: "/issues?cycle=current"}}} = live(conn, ~p"/issues")

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=current")
      render_async(view)
      assert_patch(view, ~p"/issues?cycle=12")
    end

    test "until Linear answers a cycle's link lists nothing, and a cycle the project lacks is ignored", %{
      conn: conn,
      outside: outside
    } do
      html = conn |> get(~p"/issues?cycle=12") |> html_response(200)
      assert html =~ "issues-filters-bar"
      refute html =~ "issues-list"
      refute html =~ "issues-empty-state"
      refute html =~ "cycle-toggle"

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=99&owner=usr_x")
      render_async(view)
      assert has_element?(view, "#issue-card-#{outside.id}")
      assert has_element?(view, "#cycle-toggle[aria-pressed='false']")

      view |> element("#filter-priority-medium") |> render_click()
      assert_patched(view, ~p"/issues?priority=medium")
    end

    test "Linear not answering shows no chip and lists issues as before", %{
      conn: conn,
      cycles: cycles,
      outside: outside
    } do
      stub(Issues, :get_cycles, fn _project -> {:error, :timeout} end)

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)
      refute has_element?(view, "#cycle-toggle")
      assert has_element?(view, "#issue-card-#{outside.id}")
      assert has_element?(view, "#issues-pagination")

      stub(Issues, :get_cycles, fn _project -> raise "Linear is down" end)
      {:ok, view, _html} = live(conn, ~p"/issues")
      render_async(view)
      refute has_element?(view, "#cycle-toggle")

      stub(Issues, :get_cycles, fn _project -> {:ok, cycles} end)
      {:ok, view, _html} = live(conn, ~p"/issues")
      render_async(view)
      assert has_element?(view, "#cycle-toggle")
    end

    test "one parent shows dimmed in each status group of its sub-issues, each with its own id, done count and mark", %{
      conn: conn,
      insert: insert
    } do
      parent = insert.("CYC-7", %{state: :done, state_name: "Done"})

      started =
        insert.("CYC-8", %{
          state: :in_progress,
          state_name: "In Progress",
          cycle_external_id: "cyc_12",
          parent_external_id: parent.external_id
        })

      waiting =
        insert.("CYC-9", %{
          state: :backlog,
          state_name: "Ready for Dev",
          cycle_external_id: "cyc_12",
          parent_external_id: parent.external_id
        })

      stub(Issues, :get_blockers, fn _issues ->
        %{parent.external_id => %{blocked_by: [%{issue: %Issue{identifier: "CYC-50", state: :todo}, in_project: true}]}}
      end)

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)
      render_async(view)

      for {group, child} <- [{"In Progress", started}, {"Ready for Dev", waiting}] do
        copy = "#cycle-issues section[aria-label='#{group}'] [data-context='true'][data-qa~='issue-card-#{parent.id}']"
        assert has_element?(view, copy)
        assert has_element?(view, "#{copy} [data-qa='issue-sub-issue-count']", "0/2")
        assert has_element?(view, "#{copy} [data-qa='issue-blocked'][title='Blocked by CYC-50']", "1")
        refute has_element?(view, "#{copy} [data-qa^='task-link']")
        assert has_element?(view, "#cycle-issues section[aria-label='#{group}'] #issue-card-#{child.id}")
      end

      html = render(view)
      ids = ~r/id="(issue-card-[^"]+)"/ |> Regex.scan(html, capture: :all_but_first) |> List.flatten()
      assert ids == Enum.uniq(ids)
      assert has_element?(view, "#cycle-issues section[aria-label='In Progress']", "2 issues")
    end

    test "a started row shows its stage and run by icon and words, and only a run waiting on a person flags it", %{
      conn: conn,
      insert: insert,
      open_task: open_task
    } do
      in_cycle = %{state: :in_progress, state_name: "In Progress", cycle_external_id: "cyc_12"}
      stopped = %{status: :finished}

      rows = [
        {:engineer, %{status: :blocked_on_input}, "Implement needs an answer", "pi-question", "border-l-amber-400"},
        {:engineer, %{status: :finished, error: "boom"}, "Implement failed", "pi-warning-circle", "border-l-red-500"},
        {:engineer, stopped, "Implement stopped", "pi-pause-circle", "border-l-amber-400"},
        {:plan, %{status: :finished, stage_outcome: :done}, "Review the plan", "pi-chat-text", "border-l-amber-400"},
        {:engineer, %{status: :running}, "Implement running", "pi-play-circle", "border-l-transparent"},
        {:engineer, %{status: :waiting_for_resources}, "Implement waiting for resources", "pi-hourglass-medium",
         "border-l-transparent"}
      ]

      shown =
        for {{stage, attrs, words, icon, edge}, index} <- Enum.with_index(rows) do
          issue = insert.("ROW-#{index}", in_cycle)
          open_task.(issue, stage, attrs)
          {issue, words, icon, edge}
        end

      queued = insert.("ROW-Q", in_cycle)
      {:ok, _task} = queued |> Repo.preload(:project) |> Pipeline.create_task(:engineer)

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)

      for {issue, words, icon, edge} <- shown do
        assert has_element?(view, "#task-link-#{issue.id}", words)
        assert has_element?(view, "#task-link-#{issue.id} .#{icon}")
        assert has_element?(view, "#issue-card-#{issue.id}.#{edge}")
        assert has_element?(view, "#issue-card-#{issue.id}[data-flagged='true']") == (edge != "border-l-transparent")
      end

      assert has_element?(view, "#task-link-#{queued.id}", "Queued for Implement")
      assert has_element?(view, "#task-link-#{queued.id} .pi-clock")
      refute has_element?(view, "#issue-card-#{queued.id}[data-flagged]")
    end

    test "a run with its questions unanswered needs an answer rather than reading as stopped", %{
      conn: conn,
      working: working,
      open_task: open_task
    } do
      {task, run} = open_task.(working, :engineer, %{status: :finished})
      Repo.insert!(%Question{task_id: task.id, run_id: run.id, prompt: "Which vendor?"})

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)

      assert has_element?(view, "#task-link-#{working.id}", "Implement needs an answer")
      assert has_element?(view, "#issue-card-#{working.id}[data-flagged='true']")
    end

    test "a plan sent to the tech leads reads Ready for tech lead and is not flagged", %{
      conn: conn,
      working: working,
      open_task: open_task
    } do
      {task, _run} = open_task.(working, :plan, %{status: :finished, stage_outcome: :done})
      Repo.insert!(%Round{task_id: task.id, number: 1, plan: "A plan.", ready_at: DateTime.utc_now()})

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)

      assert has_element?(view, "#task-link-#{working.id}", "Ready for tech lead")
      assert has_element?(view, "#task-link-#{working.id} .pi-seal-check")
      refute has_element?(view, "#issue-card-#{working.id}[data-flagged]")
    end

    test "a click anywhere on a started row opens its task, and a flagged one where Up next opens it", %{
      conn: conn,
      working: working,
      reviewing: reviewing,
      open_task: open_task
    } do
      {%{id: running_id}, _run} = open_task.(working, :engineer, %{status: :running})
      {%{id: asking_id}, _run} = open_task.(reviewing, :engineer, %{status: :blocked_on_input})
      asking = "/tasks/#{asking_id}?item=plan&agent=engineer"

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)

      assert has_element?(view, "#task-link-#{reviewing.id}[href='#{asking}']")
      assert has_element?(view, "#task-link-#{working.id}[href='/tasks/#{running_id}']")
      assert has_element?(view, "#issue-card-#{reviewing.id}[data-flagged='true']")
      refute has_element?(view, "#issue-no-task-#{reviewing.id}")
      refute has_element?(view, "#issue-no-task-#{working.id}")
      # Only the links stop the click, since a stop around them would silence Start at the window.
      refute has_element?(view, "#issue-card-#{working.id} div[onclick]")
      assert has_element?(view, "#task-link-#{working.id}[onclick]")

      assert {:error, {:live_redirect, %{to: ^asking}}} = view |> element("#issue-card-#{reviewing.id}") |> render_click()
      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)

      to = "/tasks/#{running_id}"
      assert {:error, {:live_redirect, %{to: ^to}}} = view |> element("#issue-card-#{working.id}") |> render_click()
    end

    test "a row with no task offers Start and opens the issue page, and a finished one offers nothing", %{
      conn: conn,
      ready: ready,
      insert: insert
    } do
      linked = insert.("ROW-U", %{state: :todo, cycle_external_id: "cyc_12", url: "https://linear.app/row-u"})
      done = insert.("ROW-D", %{state: :done, state_name: "Done", cycle_external_id: "cyc_12"})

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12&finished=true")
      render_async(view)

      assert has_element?(view, "#issue-start-#{ready.id}[aria-label='Start #{ready.identifier}']", "Start")
      refute has_element?(view, "#issue-start-#{ready.id}[phx-disable-with]")
      assert has_element?(view, "#issue-start-#{ready.id} .pi-play")
      assert has_element?(view, "#issue-card-#{linked.id} [data-qa='issue-external-link'][onclick]")
      refute has_element?(view, "#task-link-#{ready.id}")
      refute has_element?(view, "#issue-start-#{done.id}")
      refute has_element?(view, "#issue-no-task-#{done.id}")

      to = "/issues/#{ready.identifier}"
      assert {:error, {:live_redirect, %{to: ^to}}} = view |> element("#issue-card-#{ready.id}") |> render_click()
    end

    test "a started issue with no task shows No task in place of Start, whatever its status is called", %{
      conn: conn,
      cycles: cycles,
      working: working,
      reviewing: reviewing,
      insert: insert
    } do
      statuses = [%{name: "In QA", type: "started", position: 5} | cycles.statuses]
      stub(Issues, :get_cycles, fn _project -> {:ok, %{cycles | statuses: statuses}} end)
      custom = insert.("ROW-QA", %{state: :in_progress, state_name: "In QA", cycle_external_id: "cyc_12"})
      rails = insert.("ROW-IR", %{state: :in_review, state_name: nil, cycle_external_id: "cyc_12"})

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)

      for issue <- [working, reviewing, custom, rails] do
        assert has_element?(view, "#issue-no-task-#{issue.id}[href='/issues/#{issue.identifier}']", "No task")
        assert has_element?(view, "#issue-no-task-#{issue.id}[title='No task in Rail. Open the issue to start one.']")
        assert has_element?(view, "#issue-no-task-#{issue.id} .pi-minus-circle")
        # LiveView stops a live link's click itself, and a stop here would turn it into a full page load.
        refute has_element?(view, "#issue-no-task-#{issue.id}[onclick]")
        refute has_element?(view, "#issue-start-#{issue.id}")
      end
    end

    test "the No task chip and its row both open the issue page", %{conn: conn, working: working} do
      to = "/issues/#{working.identifier}"

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)
      assert {:error, {:live_redirect, %{to: ^to}}} = view |> element("#issue-no-task-#{working.id}") |> render_click()

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)
      assert {:error, {:live_redirect, %{to: ^to}}} = view |> element("#issue-card-#{working.id}") |> render_click()
    end

    test "an issue nobody has started keeps Start and no chip in every status before started", %{
      conn: conn,
      ready: ready,
      insert: insert
    } do
      triage = insert.("ROW-T1", %{state: :triage, state_name: "Triage", cycle_external_id: "cyc_12"})
      backlog = insert.("ROW-T2", %{state: :backlog, state_name: "Backlog", cycle_external_id: "cyc_12"})
      todo = insert.("ROW-T3", %{state: :todo, state_name: "Todo", cycle_external_id: "cyc_12"})

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)

      for issue <- [triage, backlog, todo, ready] do
        assert has_element?(view, "#issue-start-#{issue.id}", "Start")
        refute has_element?(view, "#issue-no-task-#{issue.id}")
      end
    end

    test "a sub-issue follows the rule on its own status, under a dimmed parent that shows neither", %{
      conn: conn,
      insert: insert
    } do
      parent = insert.("ROW-S0", %{state: :in_progress, state_name: "In Progress"})

      moving =
        insert.("ROW-S1", %{
          state: :in_progress,
          state_name: "In Progress",
          cycle_external_id: "cyc_12",
          parent_external_id: parent.external_id
        })

      waiting =
        insert.("ROW-S2", %{
          state: :backlog,
          state_name: "Ready for Dev",
          cycle_external_id: "cyc_12",
          parent_external_id: parent.external_id
        })

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)

      assert has_element?(view, "#issue-no-task-#{moving.id}", "No task")
      refute has_element?(view, "#issue-start-#{moving.id}")
      assert has_element?(view, "#issue-start-#{waiting.id}", "Start")
      refute has_element?(view, "#issue-no-task-#{waiting.id}")

      copy = "[data-context='true'][data-qa~='issue-card-#{parent.id}']"
      assert has_element?(view, copy)
      refute has_element?(view, "#{copy} [id^='issue-no-task']")
      refute has_element?(view, "#{copy} [id^='issue-start']")
    end

    test "a merged issue's row reads Merged and opens its task, also once the task is cleaned up", %{
      conn: conn,
      insert: insert
    } do
      merged = insert.("ROW-M", %{state: :done, state_name: "Done", cycle_external_id: "cyc_12"})
      {:ok, task} = merged |> Repo.preload(:project) |> Pipeline.create_task(:engineer)
      {:ok, _merged} = Pipeline.update_task(task, %{stage: :merged, cleaned_up_at: DateTime.utc_now()})
      to = "/tasks/#{task.id}"

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12&finished=true")
      render_async(view)

      assert has_element?(view, "#task-link-#{merged.id}", "Merged")
      assert has_element?(view, "#task-link-#{merged.id} .pi-git-merge")
      refute has_element?(view, "#issue-start-#{merged.id}")
      refute has_element?(view, "#issue-no-task-#{merged.id}")
      refute has_element?(view, "#issue-card-#{merged.id}[data-flagged]")
      assert {:error, {:live_redirect, %{to: ^to}}} = view |> element("#issue-card-#{merged.id}") |> render_click()
    end

    test "a reopened issue has no task, however it merged before, so its row starts one and opens the issue", %{
      conn: conn,
      insert: insert
    } do
      reopened = insert.("ROW-R", %{state: :todo, state_name: "Ready for Dev", cycle_external_id: "cyc_12"})
      {:ok, task} = reopened |> Repo.preload(:project) |> Pipeline.create_task(:engineer)
      {:ok, _merged} = Pipeline.update_task(task, %{stage: :merged, cleaned_up_at: DateTime.utc_now()})
      to = "/issues/#{reopened.identifier}"

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)

      assert has_element?(view, "#issue-start-#{reopened.id}")
      refute has_element?(view, "#task-link-#{reopened.id}")
      assert {:error, {:live_redirect, %{to: ^to}}} = view |> element("#issue-card-#{reopened.id}") |> render_click()
    end

    test "an issue reopened to In Progress after a merge shows No task and opens the issue page", %{
      conn: conn,
      insert: insert
    } do
      reopened = insert.("ROW-RP", %{state: :in_progress, state_name: "In Progress", cycle_external_id: "cyc_12"})
      {:ok, task} = reopened |> Repo.preload(:project) |> Pipeline.create_task(:engineer)
      {:ok, _merged} = Pipeline.update_task(task, %{stage: :merged, cleaned_up_at: DateTime.utc_now()})
      to = "/issues/#{reopened.identifier}"

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)

      refute has_element?(view, "#issue-start-#{reopened.id}")
      refute has_element?(view, "#task-link-#{reopened.id}")
      assert has_element?(view, "#issue-no-task-#{reopened.id}[href='#{to}']", "No task")
      assert {:error, {:live_redirect, %{to: ^to}}} = view |> element("#issue-no-task-#{reopened.id}") |> render_click()
    end

    test "a dimmed parent has no Start and no chip, and opens its task, or its page with none", %{
      conn: conn,
      insert: insert
    } do
      started = insert.("ROW-P1", %{state: :in_progress, state_name: "In Progress"})
      plain = insert.("ROW-P2", %{state: :in_progress, state_name: "In Progress"})
      {:ok, task} = started |> Repo.preload(:project) |> Pipeline.create_task(:split)

      for {parent, identifier} <- [{started, "ROW-C1"}, {plain, "ROW-C2"}] do
        insert.(identifier, %{
          state: :in_progress,
          state_name: "In Progress",
          cycle_external_id: "cyc_12",
          parent_external_id: parent.external_id
        })
      end

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)

      for parent <- [started, plain] do
        copy = "[data-context='true'][data-qa~='issue-card-#{parent.id}']"
        assert has_element?(view, copy)
        refute has_element?(view, "#{copy} [data-qa^='task-link']")
        refute has_element?(view, "#{copy} [id^='issue-start']")
        refute has_element?(view, "#{copy} [id^='issue-no-task']")
      end

      to = "/tasks/#{task.id}"

      assert {:error, {:live_redirect, %{to: ^to}}} =
               view |> element("[data-context='true'][data-qa~='issue-card-#{started.id}']") |> render_click()

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)
      to = "/issues/#{plain.identifier}"

      assert {:error, {:live_redirect, %{to: ^to}}} =
               view |> element("[data-context='true'][data-qa~='issue-card-#{plain.id}']") |> render_click()
    end

    test "a row keeps up with its run through the writers themselves, including an answer sent elsewhere", %{
      conn: conn,
      working: working,
      open_task: open_task
    } do
      stub(Rail.Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
      test_pid = self()

      stub(Tools, :start_os_process, fn spawned, _argv ->
        send(test_pid, {:resumed, spawned.id})
        {:ok, %OsProcess{run: spawned}}
      end)

      {task, %{id: run_id} = run} = open_task.(working, :engineer, %{status: :running, conversation_id: "sess_row"})

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)
      assert has_element?(view, "#task-link-#{working.id}", "Implement running")

      {:ok, parked} = Pipeline.update_run(run, %{status: :blocked_on_input})
      assert has_element?(view, "#task-link-#{working.id}", "Implement needs an answer")
      assert has_element?(view, "#issue-card-#{working.id}[data-flagged='true']")

      question = Repo.insert!(%Question{task_id: task.id, run_id: run.id, prompt: "Which vendor?"})
      {:ok, _answered} = Pipeline.answer_question(system_scope(), question, "Acme")

      assert {:ok, _delivery, _sent} =
               Pipeline.send_answers(system_scope(), Repo.preload(parked, task: :issue))

      assert_receive {:resumed, ^run_id}
      assert render(view) =~ "Implement running"
      refute has_element?(view, "#issue-card-#{working.id}[data-flagged]")
    end

    test "a new task takes the Start off its row without a reload", %{conn: conn, ready: ready} do
      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)
      assert has_element?(view, "#issue-start-#{ready.id}")

      {:ok, task} = ready |> Repo.preload(:project) |> Pipeline.create_task(:plan)
      {:ok, role} = Roles.get_role(project_id: ready.project_id, stage: :plan)

      {:ok, run} =
        Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :starting, started_at: DateTime.utc_now()})

      {:ok, _running} = Pipeline.update_run(run, %{status: :running})

      refute has_element?(view, "#issue-start-#{ready.id}")
      assert has_element?(view, "#task-link-#{ready.id}", "Plan running")
    end

    test "a webhook moving an issue swaps Start and the chip without a reload, there and back", %{
      conn: conn,
      project: project,
      ready: ready
    } do
      {:ok, workspace} = Projects.get_linear_workspace(id: project.linear_workspace_id)

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)
      assert has_element?(view, "#issue-start-#{ready.id}")

      for {state, shown, hidden} <- [
            {%{"name" => "In Progress", "type" => "started"}, "issue-no-task", "issue-start"},
            {%{"name" => "Todo", "type" => "unstarted"}, "issue-start", "issue-no-task"}
          ] do
        assert {:ok, _issue} =
                 Issues.handle_linear_webhook(workspace, %{
                   "type" => "Issue",
                   "action" => "update",
                   "data" => %{
                     "id" => ready.external_id,
                     "teamId" => "lin_team_id",
                     "identifier" => ready.identifier,
                     "title" => ready.title,
                     "cycleId" => "cyc_12",
                     "state" => state
                   }
                 })

        assert has_element?(view, "##{shown}-#{ready.id}")
        refute has_element?(view, "##{hidden}-#{ready.id}")
      end
    end

    test "a Discard on an in-progress issue brings its Start back without a reload", %{
      conn: conn,
      working: working
    } do
      stub(Rail.Git, :delete_remote_branch, fn _project, _branch -> :ok end)
      {:ok, task} = working |> Repo.preload(:project) |> Pipeline.create_task(:engineer)

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)
      assert has_element?(view, "#task-link-#{working.id}")

      assert {:ok, %Task{}} = Pipeline.discard_task(system_scope(), task)

      assert has_element?(view, "#issue-start-#{working.id}", "Start")
      refute has_element?(view, "#issue-no-task-#{working.id}")
      refute has_element?(view, "#task-link-#{working.id}")
    end

    test "a Start clicked on a row that has not caught up with In Progress still starts the issue", %{
      conn: conn,
      ready: ready
    } do
      expect(Rail.Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
      expect(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      allow(Rail.Git, self(), view.pid)
      allow(Tools, self(), view.pid)
      render_async(view)
      assert has_element?(view, "#issue-start-#{ready.id}")

      ready |> Issue.tracker_changeset(%{state: :in_progress, state_name: "In Progress"}) |> Repo.update!()
      # Sent as the event, since any other test's broadcast may have refreshed the row by now.
      render_click(view, "start_issue", %{"issue_id" => ready.id})

      assert %Task{id: task_id, stage: :plan} = Repo.get_by(Task, issue_id: ready.id)
      assert_redirect(view, ~p"/tasks/#{task_id}")
    end

    test "Start starts the issue and opens the task, without asking GitHub for a pull request", %{
      conn: conn,
      ready: ready
    } do
      reject(&Issues.link_pull_request/2)
      expect(Rail.Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
      expect(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      allow(Issues, self(), view.pid)
      allow(Rail.Git, self(), view.pid)
      allow(Tools, self(), view.pid)
      render_async(view)

      view |> element("#issue-start-#{ready.id}") |> render_click()

      assert %Task{id: task_id, stage: :plan} = Repo.get_by(Task, issue_id: ready.id)
      assert_redirect(view, ~p"/tasks/#{task_id}")
    end

    test "Start makes a linked person the owner of an unassigned issue and queues its ticket's assignee", %{
      conn: conn,
      project: project,
      insert: insert
    } do
      %{id: issue_id} =
        issue = insert.("ROW-S", %{state: :backlog, state_name: "Ready for Dev", cycle_external_id: "cyc_12"})

      {:ok, starter} =
        Users.register_oauth_user(%{github_id: "gh_row_start", login: "row_start", email: "row_start@example.com"})

      {:ok, starter} = Users.update_user(system_scope(), starter, %{project_ids: [project.id]})
      %{id: starter_id} = starter = starter |> Ecto.Changeset.change(linear_user_id: "lin_usr_row") |> Repo.update!()

      expect(Rail.Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
      expect(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)

      {:ok, view, _html} = live(log_in_user(conn, starter), ~p"/issues?cycle=12")
      allow(Rail.Git, self(), view.pid)
      allow(Tools, self(), view.pid)
      render_async(view)

      view |> element("#issue-start-#{issue_id}") |> render_click()

      assert %Issue{owner_user_id: ^starter_id} = Repo.reload!(issue)
      assert_enqueued(worker: SyncIssue, args: %{issue_id: issue_id, fields: ["owner_user_id"]})
    end

    test "a stale row whose issue has since started opens the task and leaves its run alone", %{
      conn: conn,
      ready: ready,
      open_task: open_task
    } do
      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)
      assert has_element?(view, "#issue-start-#{ready.id}")

      # Sent as the event, since any other test's broadcast may have refreshed the row by now.
      {task, run} = open_task.(ready, :plan, %{status: :running})
      reject(&Pipeline.start_task/2)
      reject(&Tools.start_os_process/2)
      allow(Pipeline, self(), view.pid)
      allow(Tools, self(), view.pid)

      render_click(view, "start_issue", %{"issue_id" => ready.id})

      assert_redirect(view, ~p"/tasks/#{task.id}")
      assert Repo.reload!(run).started_at == run.started_at
      assert [_one] = Repo.all(from t in Task, where: t.issue_id == ^ready.id)
    end

    test "a start for an issue the person cannot reach, or a finished one, starts nothing", %{
      conn: conn,
      project: project,
      insert: insert
    } do
      {:ok, granted} =
        Users.register_oauth_user(%{github_id: "gh_row_grant", login: "row_grant", email: "row_grant@example.com"})

      {:ok, granted} = Users.update_user(system_scope(), granted, %{project_ids: [project.id]})

      {:ok, %Project{id: hidden_id}} =
        Projects.create_project(system_scope(), %{
          name: "Out of Reach",
          github_repo: "example/out-of-reach",
          github_installation_id: 557,
          key: "OOR",
          default_branch: "main",
          clone_path: "/tmp/out-of-reach"
        })

      hidden = insert.("OOR-1", %{project_id: hidden_id, state: :todo})
      finished = insert.("ROW-F", %{state: :done, state_name: "Done", cycle_external_id: "cyc_12"})

      reject(&Pipeline.start_task/2)
      reject(&Pipeline.adopt_pull_request/2)
      reject(&Issues.link_pull_request/2)

      {:ok, view, _html} = live(log_in_user(conn, granted), ~p"/issues?cycle=12")
      allow(Pipeline, self(), view.pid)
      render_async(view)

      for id <- [hidden.id, finished.id, "iss_gone"] do
        assert render_click(view, "start_issue", %{"issue_id" => id}) =~ "cycle-issues"
      end

      assert [] = Repo.all(from t in Task, where: t.issue_id in ^[hidden.id, finished.id])
    end

    test "a start that fails says why, and only a row with no task can start again", %{
      conn: conn,
      ready: ready,
      insert: insert
    } do
      spawning = insert.("ROW-SP", %{state: :todo, state_name: "Todo", cycle_external_id: "cyc_12"})
      expect(Rail.Git, :get_or_create_worktree, fn _project, _task -> {:error, "no checkout"} end)
      expect(Rail.Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)

      # As the launch does: it settles the run on why it could not start, and hands it back.
      expect(Tools, :start_os_process, fn run, _argv ->
        {:ok, failed} = Pipeline.update_run(run, %{status: :finished, error: "Failed to spawn runner: :enoent"})
        {:error, {:spawn_failed, :enoent, failed}}
      end)

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      allow(Rail.Git, self(), view.pid)
      allow(Tools, self(), view.pid)
      render_async(view)

      view |> element("#issue-start-#{ready.id}") |> render_click()
      assert has_element?(view, "#flash-error", "Could not create the worktree: no checkout")
      assert has_element?(view, "#issue-start-#{ready.id}")
      refute has_element?(view, "#issue-no-task-#{ready.id}")
      refute Repo.get_by(Task, issue_id: ready.id)
      assert %Issue{state: :backlog, state_name: "Ready for Dev"} = Repo.reload!(ready)

      view |> element("#issue-start-#{spawning.id}") |> render_click()
      assert has_element?(view, "#flash-error", "Could not start the agent: :enoent")
      assert %Task{} = Repo.get_by(Task, issue_id: spawning.id)
      refute has_element?(view, "#issue-start-#{spawning.id}")
      refute has_element?(view, "#issue-no-task-#{spawning.id}")
      assert has_element?(view, "#issue-card-#{spawning.id}.border-l-red-500", "Plan failed")
    end

    test "a second tab's insert the index refuses says someone else started it, and spawns nothing", %{
      conn: conn,
      project: project,
      ready: ready
    } do
      {:ok, _first} = ready |> Repo.preload(:project) |> Pipeline.create_task(:plan)
      {:error, %Ecto.Changeset{} = refused} = project |> build_task(ready, %{stage: :plan}) |> Repo.insert()
      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)

      # The re-read has found no task, as it does while the first tab's start is still in its transaction.
      stub(Issues, :get_issue, fn _id, _opts -> {:ok, %{ready | task: nil, project: project}} end)
      expect(Pipeline, :start_task, fn _scope, _issue -> {:error, refused} end)
      allow(Issues, self(), view.pid)
      allow(Pipeline, self(), view.pid)

      render_click(view, "start_issue", %{"issue_id" => ready.id})

      assert has_element?(view, "#flash-error", "Someone else just started this issue.")
    end

    test "a start whose re-read missed a task another tab committed stops at the task, with no spawn", %{
      conn: conn,
      project: project,
      ready: ready,
      open_task: open_task
    } do
      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      render_async(view)
      {task, run} = open_task.(ready, :plan, %{status: :running})

      # The re-read has found no task, as it does while the first tab's start is still in its transaction.
      stub(Issues, :get_issue, fn _id, _opts -> {:ok, %{ready | task: nil, project: project}} end)
      stub(Rail.Git, :get_or_create_worktree, fn _project, _task -> {:ok, task.worktree_path} end)
      reject(&Tools.start_os_process/2)
      allow(Issues, self(), view.pid)
      allow(Rail.Git, self(), view.pid)
      allow(Tools, self(), view.pid)

      render_click(view, "start_issue", %{"issue_id" => ready.id})

      assert has_element?(view, "#flash-error", "Someone else just started this issue.")
      assert Repo.reload!(run).started_at == run.started_at
      assert [_one] = Repo.all(from t in Task, where: t.issue_id == ^ready.id)
    end

    test "a start takes up a linked pull request and says why it cannot", %{
      conn: conn,
      project: project,
      ready: ready,
      insert: insert
    } do
      refused_row = insert.("ROW-PR1", %{state: :todo, state_name: "Todo", cycle_external_id: "cyc_12"})
      adopted_row = insert.("ROW-PR2", %{state: :todo, state_name: "Todo", cycle_external_id: "cyc_12"})

      for {row, number} <- [{ready, 41}, {refused_row, 43}, {adopted_row, 42}] do
        row
        |> Issue.pull_request_changeset(%{pr_number: number, pr_url: "https://github.com/org/app/pull/#{number}"})
        |> Repo.update!()
      end

      reject(&Issues.link_pull_request/2)

      {:error, %Ecto.Changeset{} = refused} =
        Repo.transaction(fn ->
          {:ok, _first} = refused_row |> Repo.preload(:project) |> Pipeline.create_task(:review)
          {:error, changeset} = project |> build_task(refused_row, %{stage: :review}) |> Repo.insert()
          Repo.rollback(changeset)
        end)

      expect(Pipeline, :adopt_pull_request, fn _scope, %Issue{id: id} when id == ready.id ->
        {:error, :pull_request_from_fork}
      end)

      expect(Pipeline, :adopt_pull_request, fn _scope, %Issue{id: id} when id == refused_row.id -> {:error, refused} end)

      expect(Pipeline, :adopt_pull_request, fn _scope, %Issue{id: id} = adopted when id == adopted_row.id ->
        Pipeline.create_task(Repo.preload(adopted, :project), :review)
      end)

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=12")
      allow(Issues, self(), view.pid)
      allow(Pipeline, self(), view.pid)
      render_async(view)

      view |> element("#issue-start-#{ready.id}") |> render_click()
      assert has_element?(view, "#flash-error", "That pull request comes from a fork, which Rail cannot push fixes to.")

      view |> element("#issue-start-#{refused_row.id}") |> render_click()
      assert has_element?(view, "#flash-error", "Someone else just started this issue.")

      view |> element("#issue-start-#{adopted_row.id}") |> render_click()
      assert %Task{id: task_id, stage: :review} = Repo.get_by(Task, issue_id: adopted_row.id)
      assert_redirect(view, ~p"/tasks/#{task_id}")
    end

    test "the plain list keeps its rows: no Start, its chip, and a click on the issue page", %{
      conn: conn,
      ready: ready,
      working: working,
      reviewing: reviewing,
      open_task: open_task
    } do
      {_task, _run} = open_task.(working, :engineer, %{status: :blocked_on_input})

      {:ok, view, _html} = live(conn, ~p"/issues")
      render_async(view)

      assert has_element?(view, "#issue-card-#{reviewing.id}")
      refute has_element?(view, "#issue-no-task-#{reviewing.id}")
      refute has_element?(view, "#issue-start-#{reviewing.id}")
      refute has_element?(view, "#issue-start-#{ready.id}")
      refute has_element?(view, "#issue-card-#{working.id}[data-flagged]")
      assert has_element?(view, "#task-link-#{working.id} .pi-git-branch")
      assert has_element?(view, "#issue-card-#{working.id} div[onclick]")

      to = "/issues/#{working.identifier}"
      assert {:error, {:live_redirect, %{to: ^to}}} = view |> element("#issue-card-#{working.id}") |> render_click()
    end

    # Called directly: a live page also reloads on any other test's broadcast, so it could not show this.
    test "the plain list does not reload on a run's change, which it does not show" do
      socket = %Socket{assigns: %{__changed__: %{}, view: :list}}

      assert {:noreply, ^socket} = IssuesLive.handle_info({:pipeline_changed, "tsk_elsewhere"}, socket)
    end
  end

  describe "cycle view across projects" do
    setup %{conn: conn, project: project, github_project: github_project} do
      # A Linear project looks its team up by key when it is made.
      Req.Test.stub(Rail.Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"variables" => %{"teamKey" => key}} = Jason.decode!(body)
        Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_#{key}"}]}}})
      end)

      [another, off, dormant] =
        for {name, key, active} <- [
              {"Another Project", "ANO", true},
              {"Off Project", "OFF", true},
              {"Dormant", "DRM", false}
            ] do
          {:ok, created} =
            Projects.create_project(system_scope(), %{
              name: name,
              github_repo: "example/#{String.downcase(key)}",
              github_installation_id: 558,
              key: key,
              default_branch: "main",
              clone_path: "/tmp/#{String.downcase(key)}",
              linear_workspace_id: project.linear_workspace_id,
              active: active
            })

          created
        end

      [ana, bo] =
        for name <- ["Ana", "Bo"] do
          {:ok, user} =
            Users.register_oauth_user(%{
              github_id: "gh_xcycle_#{name}",
              login: "xcycle_#{name}",
              name: name,
              email: "xcycle_#{name}@example.com"
            })

          user
        end

      {:ok, viewer} =
        Users.register_oauth_user(%{
          github_id: "gh_xcycle_viewer",
          login: "xcycle_viewer",
          email: "xcycle_viewer@example.com",
          admin: true
        })

      cycle = fn id, number, status, current, estimate ->
        %{
          id: id,
          number: number,
          name: nil,
          starts_on: ~D[2026-10-26],
          ends_on: ~D[2026-11-08],
          status: status,
          current: current,
          scope_history: [5.0, 6.0],
          started_history: [1.0, 3.0],
          completed_history: [+0.0, 1.0],
          default_estimate: estimate
        }
      end

      answers = %{
        "TST" =>
          {:ok,
           %{
             cycles: [
               cycle.("cyc_t11", 11, :ended, false, 1),
               cycle.("cyc_t12", 12, :running, true, 1),
               cycle.("cyc_t13", 13, :upcoming, false, 1),
               cycle.("cyc_t14", 14, :upcoming, false, 1)
             ],
             statuses: [
               %{name: "Ready for Dev", type: "unstarted", position: 1},
               %{name: "In Progress", type: "started", position: 2},
               %{name: "In Review", type: "started", position: 3},
               %{name: "Done", type: "completed", position: 4}
             ]
           }},
        "ANO" =>
          {:ok,
           %{
             cycles: [
               cycle.("cyc_a3", 3, :ended, false, 3),
               cycle.("cyc_a4", 4, :ended, false, 3),
               cycle.("cyc_a5", 5, :running, true, 3)
             ],
             statuses: [
               %{name: "Todo", type: "unstarted", position: 0},
               %{name: "In Progress", type: "started", position: 1},
               %{name: "Done", type: "completed", position: 2}
             ]
           }},
        "OFF" => {:ok, %{cycles: [], statuses: []}},
        "DRM" => {:ok, %{cycles: [], statuses: []}}
      }

      test_pid = self()

      stub(Issues, :get_cycles, fn %Project{key: key} ->
        send(test_pid, {:read_cycles, key})
        answers[key]
      end)

      insert = fn identifier, project_id, attrs ->
        %Issue{}
        |> Issue.tracker_changeset(
          Map.merge(
            %{
              project_id: project_id,
              external_id: "lin_#{identifier}",
              identifier: identifier,
              title: "Title #{identifier}",
              state: :backlog
            },
            attrs
          )
        )
        |> Repo.insert!()
      end

      %{
        conn: log_in_user(conn, viewer),
        viewer: viewer,
        another: another,
        dormant: dormant,
        ana: ana,
        bo: bo,
        answers: answers,
        insert: insert,
        # Inserted before Rail's, so the urgent one is not also the most recently updated.
        a_work:
          insert.("ANO-1", another.id, %{
            state: :in_progress,
            state_name: "In Progress",
            cycle_external_id: "cyc_a5",
            owner_user_id: ana.id,
            priority: :urgent
          }),
        a_todo:
          insert.("ANO-2", another.id, %{
            state: :todo,
            state_name: "Todo",
            cycle_external_id: "cyc_a5",
            owner_user_id: bo.id,
            estimate: 2,
            priority: :low
          }),
        t_review:
          insert.("TST-1", project.id, %{
            state: :in_progress,
            state_name: "In Review",
            cycle_external_id: "cyc_t12",
            owner_user_id: ana.id,
            estimate: 3,
            priority: :high
          }),
        t_work:
          insert.("TST-2", project.id, %{
            state: :in_progress,
            state_name: "In Progress",
            cycle_external_id: "cyc_t12",
            owner_user_id: bo.id
          }),
        outside: insert.("TST-3", project.id, %{state: :backlog, state_name: "Backlog"}),
        off_issue: insert.("OFF-1", off.id, %{state: :backlog, cycle_external_id: "cyc_t12"}),
        github_issue: insert.("tgh-1", github_project.id, %{state: :backlog})
      }
    end

    test "the chip merges every project's current cycle into one list beside a panel each", %{
      conn: conn,
      viewer: viewer,
      t_review: t_review,
      t_work: t_work,
      a_work: a_work,
      a_todo: a_todo,
      outside: outside,
      off_issue: off_issue,
      github_issue: github_issue
    } do
      {:ok, view, _html} = live(conn, ~p"/issues")
      render_async(view)

      # Each active Linear project is asked once; the GitHub project and the inactive one are not.
      for key <- ["ANO", "OFF", "TST"], do: assert_received({:read_cycles, ^key})
      refute_received {:read_cycles, _another}

      assert has_element?(view, "#cycle-toggle[aria-pressed='false']", "Current cycle")
      view |> element("#cycle-toggle") |> render_click()
      assert_patched(view, ~p"/issues?cycle=current")
      assert %User{issues_filters: %{"cycle" => "current"}} = Repo.reload!(viewer)
      assert has_element?(view, "#cycle-toggle[aria-pressed='true']", "Current cycles")

      # A status both teams name shares a group, its points each team's own default; others stay apart.
      assert has_element?(view, "#cycle-issues section[aria-label='In Progress']", "2 issues")
      assert has_element?(view, "#cycle-issues section[aria-label='In Progress'] [title='4 points']")
      assert has_element?(view, "#cycle-issues section[aria-label='In Review'] #issue-card-#{t_review.id}")
      assert has_element?(view, "#cycle-issues section[aria-label='Todo'] #issue-card-#{a_todo.id}")
      refute has_element?(view, "#cycle-issues section[aria-label='Ready for Dev']")
      [_before, after_urgent] = String.split(render(view), ~s(id="issue-card-#{a_work.id}"), parts: 2)
      assert after_urgent =~ ~s(id="issue-card-#{t_work.id}")

      for issue <- [outside, off_issue, github_issue], do: refute(has_element?(view, "#issue-card-#{issue.id}"))
      assert has_element?(view, "#filter-priority-all", "All (4)")

      assert has_element?(view, "#cycle-panels #cycle-ANO-panel[aria-label='Cycle 5']")
      assert has_element?(view, "#cycle-TST-panel[aria-label='Cycle 12'] #cycle-TST-panel-toggle[aria-expanded='true']")
      assert has_element?(view, "#cycle-TST-scope", "4")
      assert has_element?(view, "#cycle-ANO-scope", "5")
      assert has_element?(view, "#cycle-TST-chart")
      assert has_element?(view, "#cycle-ANO-chart")
      refute has_element?(view, "#cycle-OFF-panel")
      refute has_element?(view, "#cycle-panel")
      [_before, after_another] = String.split(render(view), ~s(id="cycle-ANO-panel"), parts: 2)
      assert after_another =~ ~s(id="cycle-TST-panel")

      # Ana owns work in both cycles, and still no id repeats.
      ids = ~r/id="(cycle-[^"]+)"/ |> Regex.scan(render(view), capture: :all_but_first) |> List.flatten()
      assert ids == Enum.uniq(ids)
    end

    test "a closed panel is one row with its share done, and stays closed through a reload and a step", %{
      conn: conn,
      t_work: t_work
    } do
      {:ok, view, _html} = live(conn, ~p"/issues?cycle=current")
      render_async(view)

      view |> element("#cycle-TST-panel-toggle") |> render_click()
      refute has_element?(view, "#cycle-TST-panel")
      assert has_element?(view, "#cycle-TST-panel-toggle[aria-expanded='false']", "Cycle 12")
      assert has_element?(view, "#cycle-TST-panel-toggle", ~r/0%\s*of 4/)
      assert has_element?(view, "#cycle-TST-panel-dates", "Oct 26 – Nov 8")
      assert has_element?(view, "#cycle-ANO-panel")

      Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, t_work.id})
      assert has_element?(view, "#cycle-TST-panel-toggle[aria-expanded='false']", "Cycle 12")

      view |> element("#cycle-previous") |> render_click()
      assert has_element?(view, "#cycle-TST-panel-toggle[aria-expanded='false']", "Cycle 11")
      assert has_element?(view, "#cycle-ANO-panel[aria-label='Cycle 4']")

      view |> element("#cycle-TST-panel-toggle") |> render_click()
      assert has_element?(view, "#cycle-TST-panel[aria-label='Cycle 11']")
    end

    test "filters narrow rows in every project while each panel's figures stay its whole cycle", %{
      conn: conn,
      ana: ana,
      bo: bo,
      t_review: t_review,
      t_work: t_work,
      a_work: a_work,
      a_todo: a_todo
    } do
      {:ok, view, _html} = live(conn, ~p"/issues?cycle=current")
      render_async(view)

      view |> element("#filter-priority-urgent") |> render_click()
      assert_patched(view, ~p"/issues?priority=urgent&cycle=current")
      assert has_element?(view, "#issue-card-#{a_work.id}")
      refute has_element?(view, "#issue-card-#{t_review.id}")
      assert has_element?(view, "#cycle-TST-scope", "4")
      assert has_element?(view, "#cycle-ANO-scope", "5")

      view |> element("#filter-priority-all") |> render_click()
      view |> element("#issues-search-form") |> render_change(%{"q" => "ANO"})
      assert has_element?(view, "#issue-card-#{a_todo.id}")
      refute has_element?(view, "#issue-card-#{t_work.id}")
      view |> element("#issues-search-form") |> render_change(%{"q" => ""})

      view |> element("#cycle-TST-owner-#{ana.id}") |> render_click()
      assert_patched(view, ~p"/issues?cycle=current&owner=#{ana.id}")
      assert has_element?(view, "#issue-card-#{t_review.id}")
      assert has_element?(view, "#issue-card-#{a_work.id}")
      refute has_element?(view, "#issue-card-#{t_work.id}")
      refute has_element?(view, "#issue-card-#{a_todo.id}")
      assert has_element?(view, "#cycle-ANO-owner-#{ana.id}[aria-pressed='true']", "Clear filter")
      assert has_element?(view, "#cycle-TST-scope", "4")
      assert has_element?(view, "#cycle-ANO-scope", "5")

      # The chip keeps the filter in sight with every panel closed, and clears it.
      view |> element("#cycle-TST-panel-toggle") |> render_click()
      view |> element("#cycle-ANO-panel-toggle") |> render_click()
      assert has_element?(view, "#cycle-owner-chip[title='Clear filter']", "Ana")
      view |> element("#cycle-owner-chip") |> render_click()
      assert_patched(view, ~p"/issues?cycle=current")
      refute has_element?(view, "#cycle-owner-chip")
      assert has_element?(view, "#issue-card-#{t_work.id}")

      view |> element("#cycle-ANO-panel-toggle") |> render_click()
      view |> element("#cycle-ANO-owner-#{bo.id}") |> render_click()
      assert_patched(view, ~p"/issues?cycle=current&owner=#{bo.id}")
      view |> element("#cycle-ANO-owner-#{bo.id}") |> render_click()
      assert_patched(view, ~p"/issues?cycle=current")

      # My issues adds no chip; the viewer owns nothing here, so nothing lists.
      view |> element("#issues-mine") |> render_click()
      assert_patched(view, ~p"/issues?mine=true&cycle=current")
      assert has_element?(view, "[data-qa='empty-state-title']", "No issues in these cycles")
      refute has_element?(view, "#cycle-owner-chip")
      assert has_element?(view, "#cycle-ANO-scope", "5")

      # An owner with nothing in the cycles shown is no filter at all.
      {:ok, view, _html} = live(conn, ~p"/issues?cycle=current&owner=usr_nobody")
      render_async(view)
      assert has_element?(view, "#issue-card-#{t_work.id}")
      refute has_element?(view, "#cycle-owner-chip")
    end

    test "the arrows step each project through its own cycles and drop a project with none there", %{
      conn: conn,
      viewer: viewer,
      another: another,
      insert: insert,
      outside: outside
    } do
      ended = insert.("ANO-3", another.id, %{state: :done, state_name: "Done", cycle_external_id: "cyc_a3"})

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=current")
      render_async(view)

      view |> element("#cycle-previous") |> render_click()
      assert_patched(view, ~p"/issues?cycle=current&offset=-1")
      assert has_element?(view, "#cycle-toggle", "Previous cycles")
      assert has_element?(view, "#cycle-TST-panel[aria-label='Cycle 11']")
      assert has_element?(view, "#cycle-ANO-panel[aria-label='Cycle 4']")
      assert %User{issues_filters: %{}} = Repo.reload!(viewer)

      view |> element("#cycle-previous") |> render_click()
      assert_patched(view, ~p"/issues?cycle=current&offset=-2")
      assert has_element?(view, "#cycle-toggle", "2 cycles back")
      refute has_element?(view, "#cycle-TST-panel")
      assert has_element?(view, "#cycle-ANO-panel[aria-label='Cycle 3']")
      assert has_element?(view, "#cycle-previous[disabled]")
      assert has_element?(view, "[data-qa='empty-state-title']", "No issues in these cycles")

      view |> element("#issues-show-finished") |> render_click()
      assert_patched(view, ~p"/issues?finished=true&cycle=current&offset=-2")
      assert has_element?(view, "#cycle-issues section[aria-label='Done'] #issue-card-#{ended.id}")

      view |> element("#cycle-next") |> render_click()
      assert_patched(view, ~p"/issues?finished=true&cycle=current&offset=-1")
      view |> element("#cycle-next") |> render_click()
      assert_patched(view, ~p"/issues?finished=true&cycle=current")

      view |> element("#cycle-next") |> render_click()
      assert_patched(view, ~p"/issues?finished=true&cycle=current&offset=1")
      assert has_element?(view, "#cycle-toggle", "Next cycles")
      refute has_element?(view, "#cycle-ANO-panel")
      view |> element("#cycle-next") |> render_click()
      assert has_element?(view, "#cycle-toggle", "2 cycles ahead")
      assert has_element?(view, "#cycle-TST-panel[aria-label='Cycle 14']")
      assert has_element?(view, "#cycle-next[disabled]")

      view |> element("#cycle-toggle") |> render_click()
      assert_patched(view, ~p"/issues?finished=true")

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=current&offset=abc")
      render_async(view)
      assert has_element?(view, "#cycle-toggle", "Current cycles")

      # An offset no project reaches, and a number, which names no cycle across projects, list issues.
      for path <- [~p"/issues?cycle=current&offset=-7", ~p"/issues?cycle=12"] do
        {:ok, view, _html} = live(conn, path)
        render_async(view)
        assert has_element?(view, "#issue-card-#{outside.id}")
        assert has_element?(view, "#cycle-toggle[aria-pressed='false']")
        view |> element("#filter-priority-medium") |> render_click()
        assert_patched(view, ~p"/issues?priority=medium")
      end
    end

    test "Linear not answering for one project names it in that project's place, and for every project shows no chip",
         %{conn: conn, answers: answers, a_work: a_work, t_work: t_work, outside: outside} do
      for failure <- [fn -> {:error, :timeout} end, fn -> raise "Linear is down" end] do
        stub(Issues, :get_cycles, fn
          %Project{key: "ANO"} -> failure.()
          %Project{key: key} -> answers[key]
        end)

        {:ok, view, _html} = live(conn, ~p"/issues?cycle=current")
        render_async(view)
        assert has_element?(view, "#cycle-TST-panel")
        assert has_element?(view, "#cycle-ANO-failed", "Linear did not answer, so these issues are not listed.")
        refute has_element?(view, "#cycle-ANO-panel")
        refute has_element?(view, "#issue-card-#{a_work.id}")
        assert has_element?(view, "#issue-card-#{t_work.id}")
      end

      stub(Issues, :get_cycles, fn _project -> {:error, :timeout} end)
      {:ok, view, _html} = live(conn, ~p"/issues?cycle=current")
      render_async(view)
      refute has_element?(view, "#cycle-toggle")
      refute has_element?(view, "#cycle-panels")
      assert has_element?(view, "#issue-card-#{outside.id}")
      assert has_element?(view, "#issues-pagination")
    end

    test "a person granted one project sees only its cycle, and no other project is asked", %{
      conn: conn,
      project: project,
      t_work: t_work,
      a_work: a_work
    } do
      {:ok, user} =
        Users.register_oauth_user(%{
          github_id: "gh_xcycle_granted",
          login: "xcycle_granted",
          email: "xcycle_granted@example.com"
        })

      {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})

      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues?cycle=current")
      render_async(view)
      assert_received {:read_cycles, "TST"}
      refute_received {:read_cycles, _another}
      assert has_element?(view, "#cycle-TST-panel")
      refute has_element?(view, "#cycle-ANO-panel")
      assert has_element?(view, "#issue-card-#{t_work.id}")
      refute has_element?(view, "#issue-card-#{a_work.id}")
    end

    test "a saved cycle view opens on the current cycles, and on one project's by its number", %{
      conn: conn,
      viewer: viewer,
      project: project
    } do
      {:ok, _viewer} = Users.set_issues_filters(Scope.for_user(viewer), %{"cycle" => "current"})

      assert {:error, {:live_redirect, %{to: "/issues?cycle=current"}}} = live(conn, ~p"/issues")
      {:ok, view, _html} = live(conn, ~p"/issues?cycle=current")
      render_async(view)
      assert has_element?(view, "#cycle-toggle[aria-pressed='true']", "Current cycles")
      assert has_element?(view, "#cycle-ANO-panel")

      {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: project.id}), ~p"/issues?cycle=current")
      render_async(view)
      assert_patch(view, ~p"/issues?cycle=12")
      assert has_element?(view, "#cycle-panel[aria-label='Cycle 12']")
    end

    test "in two tabs, an issue leaving one cycle and another finishing update their rows and own figures only", %{
      conn: conn,
      project: project,
      t_work: t_work,
      a_todo: a_todo
    } do
      {:ok, workspace} = Projects.get_linear_workspace(id: project.linear_workspace_id)
      tabs = for _tab <- 1..2, do: conn |> live(~p"/issues?cycle=current") |> elem(1)
      Enum.each(tabs, &render_async/1)

      assert {:ok, _issue} =
               Issues.handle_linear_webhook(workspace, %{
                 "type" => "Issue",
                 "action" => "update",
                 "data" => %{
                   "id" => a_todo.external_id,
                   "teamId" => "lin_team_ANO",
                   "identifier" => "ANO-2",
                   "title" => "Title ANO-2",
                   "estimate" => 2,
                   "state" => %{"name" => "Todo", "type" => "unstarted"}
                 },
                 "updatedFrom" => %{"cycleId" => "cyc_a5"}
               })

      for view <- tabs do
        refute has_element?(view, "#issue-card-#{a_todo.id}")
        assert has_element?(view, "#cycle-ANO-scope", "3")
        assert has_element?(view, "#cycle-TST-scope", "4")
      end

      assert {:ok, _issue} =
               Issues.handle_linear_webhook(workspace, %{
                 "type" => "Issue",
                 "action" => "update",
                 "data" => %{
                   "id" => t_work.external_id,
                   "teamId" => "lin_team_id",
                   "identifier" => "TST-2",
                   "title" => "Title TST-2",
                   "cycleId" => "cyc_t12",
                   "state" => %{"name" => "Done", "type" => "completed"}
                 }
               })

      for view <- tabs do
        refute has_element?(view, "#issue-card-#{t_work.id}")
        assert has_element?(view, "#cycle-TST-completed", "1")
        assert has_element?(view, "#cycle-ANO-scope", "3")
        assert has_element?(view, "#cycle-ANO-completed", "0")
      end
    end
  end

  describe "sub-issues and blockers in All issues" do
    setup %{conn: conn, project: project} do
      {:ok, user} =
        Users.register_oauth_user(%{
          github_id: "gh_nest_viewer",
          login: "nest_viewer",
          email: "nest_viewer@example.com",
          admin: true
        })

      insert = fn identifier, attrs ->
        %Issue{}
        |> Issue.tracker_changeset(
          Map.merge(
            %{
              project_id: project.id,
              external_id: "lin_#{identifier}",
              identifier: identifier,
              title: "Title #{identifier}",
              state: :todo
            },
            attrs
          )
        )
        |> Repo.insert!()
      end

      %{conn: log_in_user(conn, user), insert: insert}
    end

    test "a sub-issue sits under its parent's row, or under a dimmed copy the page range does not count", %{
      conn: conn,
      insert: insert
    } do
      parent = insert.("NST-1", %{priority: :low})
      done = insert.("NST-2", %{priority: :high, parent_external_id: parent.external_id, state: :done})
      child = insert.("NST-3", %{priority: :high, parent_external_id: parent.external_id})

      {:ok, view, _html} = live(conn, ~p"/issues")

      assert has_element?(view, "#issue-card-#{parent.id}:not([data-context])")
      assert has_element?(view, "#issue-card-#{parent.id} [data-qa='issue-sub-issue-count']", "1/2")
      assert has_element?(view, "#issue-card-#{child.id} .border-l")
      refute has_element?(view, "#issue-card-#{done.id}")
      [_before, after_parent] = String.split(render(view), ~s(id="issue-card-#{parent.id}"), parts: 2)
      assert after_parent =~ ~s(id="issue-card-#{child.id}")

      view |> element("#filter-priority-high") |> render_click()
      assert has_element?(view, "#issue-card-#{parent.id}-above-#{child.id}[data-context='true']")
      assert has_element?(view, "#issue-card-#{child.id}")
      assert has_element?(view, "#issues-page-range", "Showing 1–1 of 1")
    end

    test "a blocked row carries a red mark naming its open blockers, and none once every blocker is finished", %{
      conn: conn,
      insert: insert,
      project: project
    } do
      blocked = insert.("NST-4", %{})
      blocker = insert.("NST-5", %{})
      finished = %Issue{identifier: "NST-6", state: :done}

      stub(Issues, :get_blockers, fn _issues ->
        %{
          blocked.external_id => %{
            blocked_by: [
              %{issue: Repo.get!(Issue, blocker.id), in_project: true},
              %{issue: finished, in_project: false}
            ],
            blocks: []
          }
        }
      end)

      {:ok, view, _html} = live(conn, ~p"/issues?finished=true")
      render_async(view)

      assert has_element?(view, "#issue-card-#{blocked.id} [data-qa='issue-blocked'][title='Blocked by NST-5']", "1")
      refute has_element?(view, "#issue-card-#{blocker.id} [data-qa='issue-blocked']")

      # The blocker finishing in Linear takes the mark off, read again since Linear sends nothing for relations.
      {:ok, workspace} = Projects.get_linear_workspace(id: project.linear_workspace_id)

      assert {:ok, _issue} =
               Issues.handle_linear_webhook(workspace, %{
                 "type" => "Issue",
                 "action" => "update",
                 "data" => %{
                   "id" => blocker.external_id,
                   "teamId" => "lin_team_id",
                   "identifier" => "NST-5",
                   "title" => "Title NST-5",
                   "state" => %{"name" => "Done", "type" => "completed"}
                 }
               })

      render_async(view)
      refute has_element?(view, "#issue-card-#{blocked.id} [data-qa='issue-blocked']")
    end

    test "a blocker from another project finishing takes its mark off without a reload", %{
      conn: conn,
      insert: insert,
      project: project
    } do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_other"}]}}})
      end)

      {:ok, other_project} =
        Projects.create_project(system_scope(), %{
          name: "Other Linear project",
          github_repo: "example/other-linear",
          github_installation_id: 557,
          key: "OTHILS",
          default_branch: "main",
          clone_path: "/tmp/other-linear",
          linear_workspace_id: project.linear_workspace_id
        })

      blocked = insert.("NST-7", %{})
      blocker = insert.("OTHILS-1", %{project_id: other_project.id})

      stub(Issues, :get_blockers, fn issues -> call_original(Issues, :get_blockers, [issues]) end)

      Req.Test.stub(Rail.Linear, fn conn ->
        state_type = if Repo.get!(Issue, blocker.id).state == :done, do: "completed", else: "started"

        Req.Test.json(conn, %{
          "data" => %{
            "issues" => %{
              "nodes" => [
                %{
                  "id" => blocked.external_id,
                  "relations" => %{"nodes" => []},
                  "inverseRelations" => %{
                    "nodes" => [
                      %{
                        "type" => "blocks",
                        "issue" => %{
                          "id" => blocker.external_id,
                          "identifier" => "OTHILS-1",
                          "title" => "Secret title",
                          "url" => "https://linear.app/issue/OTHILS-1",
                          "state" => %{"name" => state_type, "type" => state_type}
                        }
                      }
                    ]
                  }
                }
              ]
            }
          }
        })
      end)

      conn = init_test_session(conn, %{selected_project_id: project.id})
      {:ok, view, _html} = live(conn, ~p"/issues")
      render_async(view)
      assert has_element?(view, "#issue-card-#{blocked.id} [data-qa='issue-blocked'][title='Blocked by OTHILS-1']", "1")

      blocker |> Issue.tracker_changeset(%{state: :done}) |> Repo.update!()
      Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, blocker.id})

      render_async(view)
      refute has_element?(view, "#issue-card-#{blocked.id} [data-qa='issue-blocked']")
    end

    test "a Rail-tracked issue's edits and blockers reach the list without a reload, and others' relations do not", %{
      conn: conn
    } do
      key = "Lst#{System.unique_integer([:positive])}"

      {:ok, local} =
        Projects.create_project(system_scope(), %{
          name: "Rail-tracked",
          github_repo: "example/#{key}",
          github_installation_id: 1,
          tracker: :local,
          key: key,
          default_branch: "main",
          clone_path: "/tmp/#{key}"
        })

      {:ok, %Issue{id: blocked_id} = blocked} = Issues.create_issue(system_scope(), local, %{title: "Waits"})

      {:ok, %Issue{identifier: blocker_identifier} = blocker} =
        Issues.create_issue(system_scope(), local, %{title: "Goes first"})

      stub(Issues, :get_blockers, fn issues -> call_original(Issues, :get_blockers, [issues]) end)

      conn = init_test_session(conn, %{selected_project_id: local.id})
      {:ok, view, _html} = live(conn, ~p"/issues")
      render_async(view)
      refute has_element?(view, "#issue-card-#{blocked_id} [data-qa='issue-blocked']")

      {:ok, _issue} = Issues.edit_issue(system_scope(), blocked, %{"title" => "Waits its turn", "priority" => "urgent"})
      assert has_element?(view, "#issue-card-#{blocked_id} [data-qa='issue-title']", "Waits its turn")
      assert has_element?(view, "#issue-card-#{blocked_id} [data-qa='issue-priority-badge']", "Urgent")

      :ok = Issues.block_issue(system_scope(), blocker, blocked)
      render_async(view)

      assert has_element?(
               view,
               "#issue-card-#{blocked_id} [data-qa='issue-blocked'][title='Blocked by #{blocker_identifier}']"
             )

      # A relation between issues the list does not show reads nothing again.
      stub(Issues, :get_blockers, fn _issues -> raise "read again" end)
      send(view.pid, {:issue_relations_changed, ["iss_elsewhere", "iss_other"]})
      render_async(view)
      assert has_element?(view, "#issue-card-#{blocked_id} [data-qa='issue-blocked']")
    end

    test "a relation change while the cycle view waits on its trackers leaves the page waiting", %{conn: conn} do
      stub(Issues, :get_cycles, fn _project -> Process.sleep(:infinity) end)
      {:ok, view, _html} = live(conn, ~p"/issues?cycle=current")

      send(view.pid, {:issue_relations_changed, ["iss_elsewhere", "iss_other"]})
      assert render(view) =~ "Issues"
      refute has_element?(view, "#issues-pagination")
    end

    test "blockers Linear fails to read leave the rows unmarked", %{conn: conn, insert: insert} do
      blocked = insert.("NST-7", %{})
      stub(Issues, :get_blockers, fn _issues -> raise "Linear is down" end)

      {:ok, view, _html} = live(conn, ~p"/issues")
      render_async(view)

      assert has_element?(view, "#issue-card-#{blocked.id}")
      refute has_element?(view, "[data-qa='issue-blocked']")
    end

    test "a GitHub project asks nobody for cycles, and All projects asks each active Linear project once", %{
      conn: conn,
      github_project: github_project
    } do
      test_pid = self()

      stub(Issues, :get_cycles, fn project ->
        send(test_pid, {:read_cycles, project.key})
        {:ok, %{cycles: [], statuses: []}}
      end)

      {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: github_project.id}), ~p"/issues")
      render_async(view)
      refute has_element?(view, "#cycle-toggle")
      refute_received {:read_cycles, _key}

      {:ok, view, _html} = live(conn, ~p"/issues")
      render_async(view)
      refute has_element?(view, "#cycle-toggle")
      assert_received {:read_cycles, "TST"}
      refute_received {:read_cycles, _another}
    end
  end

  describe "a Rail-tracked project's cycles" do
    setup %{conn: conn, github_project: github_project} do
      stub(Issues, :get_cycles, fn project -> call_original(Issues, :get_cycles, [project]) end)
      key = "ILC#{System.unique_integer([:positive])}"

      {:ok, local} =
        Projects.create_project(system_scope(), %{
          name: "Cycles page",
          github_repo: "example/#{key}",
          github_installation_id: 1,
          tracker: :local,
          key: key,
          default_branch: "main",
          clone_path: "/tmp/#{key}"
        })

      {:ok, viewer} =
        Users.register_oauth_user(%{
          github_id: "gh_local_cycles",
          login: "local_cycles",
          email: "local_cycles@example.com"
        })

      {:ok, viewer} = Users.update_user(system_scope(), viewer, %{project_ids: [local.id, github_project.id]})

      %{conn: conn |> log_in_user(viewer) |> init_test_session(%{selected_project_id: local.id}), local: local}
    end

    test "a page open when the first nightly run makes Cycle 1 gains Current cycle, opening on it empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/issues")
      render_async(view)
      refute has_element?(view, "#cycle-toggle")

      :ok = Issues.close_cycle_day(Date.utc_today())
      render_async(view)

      view |> element("#cycle-toggle", "Current cycle") |> render_click()
      assert_patched(view, ~p"/issues?cycle=1")
      assert has_element?(view, "#cycle-toggle[aria-pressed='true']", "Cycle 1")
      assert has_element?(view, "#issues-empty-state", "No issues in Cycle 1")
      assert has_element?(view, "#cycle-panel-tag", "Current")
      assert has_element?(view, "#cycle-previous[disabled]")
      assert has_element?(view, "#cycle-next:not([disabled])")
    end

    test "a GitHub project offers no cycles, and pays no heed to another project's", %{
      conn: conn,
      github_project: github_project,
      local: local
    } do
      {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: github_project.id}), ~p"/issues")
      render_async(view)

      :ok = Issues.close_cycle_day(Date.utc_today())
      render_async(view)

      refute has_element?(view, "#cycle-toggle")
      assert {:ok, %{cycles: [_first, _second, _third]}} = Issues.get_cycles(local)
    end

    test "Edit dates locks a running cycle's start, refuses an overlap, and a saved edit moves the panel's dates", %{
      conn: conn
    } do
      today = Date.utc_today()
      :ok = Issues.close_cycle_day(today)
      day = &Calendar.strftime(&1, "%b %-d")

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=1")
      render_async(view)

      view |> element("#cycle-edit-dates") |> render_click()
      assert has_element?(view, "#cycle-dates-title", "Edit Cycle 1 dates")
      assert has_element?(view, "#cycle-dates-starts[disabled]")
      assert has_element?(view, "#cycle-dates-start-locked", "A running cycle keeps its start")

      view |> element("#cycle-dates-form") |> render_change(%{"cycle" => %{"ends_on" => Date.add(today, -1)}})
      assert has_element?(view, "#cycle-dates-error", "A running cycle cannot end before today.")

      view |> element("#cycle-dates-form") |> render_submit(%{"cycle" => %{"ends_on" => Date.add(today, 16)}})
      refute has_element?(view, "#cycle-dates-dialog")
      render_async(view)
      assert has_element?(view, "#cycle-panel-dates", "#{day.(today)} – #{day.(Date.add(today, 16))}")

      view |> element("#cycle-next") |> render_click()
      assert_patched(view, ~p"/issues?cycle=2")
      view |> element("#cycle-edit-dates") |> render_click()
      refute has_element?(view, "#cycle-dates-starts[disabled]")

      view
      |> element("#cycle-dates-form")
      |> render_submit(%{"cycle" => %{"starts_on" => Date.add(today, 16), "ends_on" => Date.add(today, 30)}})

      assert has_element?(view, "#cycle-dates-error", "These dates overlap an earlier cycle.")
      assert has_element?(view, "#cycle-panel-dates", "#{day.(Date.add(today, 17))} – ")

      render_keydown(view, "close_cycle_dates", %{"key" => "Escape"})
      refute has_element?(view, "#cycle-dates-dialog")
    end

    test "Cancel closes the dialog, and a save after it closed or one the project refuses changes nothing", %{
      conn: conn,
      local: local
    } do
      :ok = Issues.close_cycle_day(Date.utc_today())
      {:ok, %{cycles: [%{id: first_id, ends_on: ends_on} | _later]}} = Issues.get_cycles(local)
      {:ok, view, _html} = live(conn, ~p"/issues?cycle=1")
      render_async(view)

      view |> element("#cycle-edit-dates") |> render_click()
      view |> element("#cycle-dates-cancel") |> render_click()
      refute has_element?(view, "#cycle-dates-dialog")

      render_hook(view, "save_cycle_dates", %{"cycle" => %{"ends_on" => Date.add(ends_on, 3)}})
      render_hook(view, "validate_cycle_dates", %{"cycle" => %{"ends_on" => Date.add(ends_on, 3)}})
      render_hook(view, "edit_cycle_dates", %{"cycle_id" => "cyc_unknown"})
      refute has_element?(view, "#cycle-dates-dialog")

      stub(Issues, :update_cycle, fn _scope, _project, ^first_id, _attrs -> {:error, :not_found} end)
      view |> element("#cycle-edit-dates") |> render_click()
      view |> element("#cycle-dates-form") |> render_submit(%{"cycle" => %{"ends_on" => Date.add(ends_on, 3)}})
      refute has_element?(view, "#cycle-dates-dialog")
      assert {:ok, %{cycles: [%{ends_on: ^ends_on} | _later]}} = Issues.get_cycles(local)
    end

    test "each row in a cycle names it, and an ended cycle's rows keep the state it closed in but act on the issue now",
         %{conn: conn, local: local} do
      # Cycle 1 runs Nov 10 to 23 and closes holding `rolled` and `merged` In Progress, and `kept` Done.
      :ok = Issues.close_cycle_day(~D[2026-11-10])
      stub(Date, :utc_today, fn -> ~D[2026-11-12] end)
      {:ok, %{cycles: [first | _later]}} = Issues.get_cycles(local)
      {:ok, %{id: rolled_id} = rolled} = Issues.create_issue(system_scope(), local, %{title: "Rolls over"})
      {:ok, %{id: merged_id} = merged} = Issues.create_issue(system_scope(), local, %{title: "Merges"})
      {:ok, %{id: kept_id} = kept} = Issues.create_issue(system_scope(), local, %{title: "Stays"})
      {:ok, task} = merged |> Repo.preload(:project) |> Pipeline.create_task(:engineer)
      in_progress = %{id: "in_progress", name: "In Progress", state: :in_progress}
      done = %{id: "done", name: "Done", state: :done}

      for issue <- [rolled, merged, kept] do
        {:ok, _issue} = Issues.set_issue_cycle(system_scope(), issue, first.id)
      end

      {:ok, rolled} = Issues.set_issue_status(system_scope(), rolled, in_progress)
      {:ok, merged} = Issues.set_issue_status(system_scope(), merged, in_progress)
      {:ok, kept} = Issues.set_issue_status(system_scope(), kept, done)
      :ok = Issues.close_cycle_day(~D[2026-11-24])

      # In Cycle 2, `rolled` is finished by hand, `merged` by its task merging, and `kept` is reopened.
      stub(Date, :utc_today, fn -> ~D[2026-11-25] end)
      {:ok, _done} = Issues.set_issue_status(system_scope(), rolled, done)
      {:ok, _merged} = Pipeline.update_task(task, %{stage: :merged, cleaned_up_at: DateTime.utc_now()})
      {:ok, _done} = Issues.set_issue_status(system_scope(), merged, done)
      {:ok, _reopened} = Issues.set_issue_status(system_scope(), kept, %{id: "todo", name: "Todo", state: :todo})
      {:ok, %{id: loose_id}} = Issues.create_issue(system_scope(), local, %{title: "In no cycle"})

      {:ok, view, _html} = live(conn, ~p"/issues?finished=true")
      render_async(view)

      assert has_element?(view, "#issue-cycle-#{rolled_id}", "Cycle 2")
      assert has_element?(view, "#issue-cycle-#{kept_id}", "Cycle 1")
      assert has_element?(view, "#issue-card-#{loose_id}")
      refute has_element?(view, "#issue-cycle-#{loose_id}")

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=1&finished=true")
      render_async(view)

      assert has_element?(view, "#cycle-issues section[aria-label='In Progress'] #issue-card-#{rolled_id}")
      assert has_element?(view, "#issue-cycle-#{rolled_id}", "Cycle 2")
      assert has_element?(view, "#status-picker-#{rolled_id}-trigger[title='Done']")
      refute has_element?(view, "#issue-no-task-#{rolled_id}")
      refute has_element?(view, "#issue-start-#{rolled_id}")

      assert has_element?(view, "#cycle-issues section[aria-label='In Progress'] #issue-card-#{merged_id}")
      assert has_element?(view, "#task-link-#{merged_id}", "Merged")
      refute has_element?(view, "#issue-no-task-#{merged_id}")

      assert has_element?(view, "#cycle-issues section[aria-label='Done'] #issue-card-#{kept_id}")
      assert has_element?(view, "#status-picker-#{kept_id}-trigger[title='Todo']")
      assert has_element?(view, "#issue-start-#{kept_id}")
      refute has_element?(view, "#issue-cycle-#{kept_id}")
      refute has_element?(view, "#cycle-edit-dates")
    end

    test "a page open on the current cycle gains an issue started by status, and the issues the nightly run rolls in",
         %{conn: conn, local: local} do
      stub(Date, :utc_today, fn -> ~D[2026-11-10] end)
      :ok = Issues.close_cycle_day(~D[2026-11-10])
      {:ok, %{cycles: [first, second | _later]}} = Issues.get_cycles(local)
      {:ok, %{id: started_id} = started} = Issues.create_issue(system_scope(), local, %{title: "Started now"})
      {:ok, %{id: planned_id} = planned} = Issues.create_issue(system_scope(), local, %{title: "Planned"})
      {:ok, _planned} = Issues.set_issue_cycle(system_scope(), planned, first.id)

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=1")
      render_async(view)
      refute has_element?(view, "#issue-card-#{started_id}")

      {:ok, _started} =
        Issues.set_issue_status(system_scope(), started, %{id: "in_progress", name: "In Progress", state: :in_progress})

      assert has_element?(view, "#cycle-issues section[aria-label='In Progress'] #issue-card-#{started_id}")

      {:ok, view, _html} = live(conn, ~p"/issues?cycle=2")
      render_async(view)
      refute has_element?(view, "#issue-card-#{planned_id}")

      stub(Date, :utc_today, fn -> second.starts_on end)
      :ok = Issues.close_cycle_day(second.starts_on)
      render_async(view)

      assert has_element?(view, "#cycle-panel-tag", "Current")
      assert has_element?(view, "#issue-card-#{planned_id}")
      assert has_element?(view, "#issue-card-#{started_id}")
    end
  end
end
