defmodule RailWeb.IssuesLiveTest do
  use RailWeb.ConnCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Phoenix.LiveViewTest
  import Rail.Pipeline.Utils.BuildTask

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Issues.Workers.LinearSync
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User
  alias Rail.Workflows.Schemas.Workflow
  alias Rail.Workflows.Schemas.WorkflowDefinition

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
               key: "ISS",
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
        key: "HID",
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
        key: "SYN",
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

      %{
        conn: conn |> log_in_user(viewer) |> init_test_session(%{selected_project_id: project.id}),
        viewer: viewer,
        ana: ana,
        bo: bo,
        cycles: cycles,
        insert: insert,
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
      assert has_element?(view, "#cycle-scope", "6")
      assert has_element?(view, "#cycle-started", "5")
      assert has_element?(view, "#cycle-scope", "+20% since Oct 26")
      assert has_element?(view, "#cycle-chart")
      assert has_element?(view, "#filter-priority-all", "All (3)")
      assert has_element?(view, "#filter-priority-high", "High (1)")

      view |> element("#cycle-toggle") |> render_click()
      assert_patched(view, ~p"/issues")
      assert has_element?(view, "#issue-card-#{outside.id}")
      assert %User{issues_filters: %{}} = Repo.reload!(viewer)
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
          key: "OTH",
          default_branch: "main",
          clone_path: "/tmp/other-linear",
          linear_workspace_id: project.linear_workspace_id
        })

      blocked = insert.("NST-7", %{})
      blocker = insert.("OTH-1", %{project_id: other_project.id})

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
                          "identifier" => "OTH-1",
                          "title" => "Secret title",
                          "url" => "https://linear.app/issue/OTH-1",
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
      assert has_element?(view, "#issue-card-#{blocked.id} [data-qa='issue-blocked'][title='Blocked by OTH-1']", "1")

      blocker |> Issue.tracker_changeset(%{state: :done}) |> Repo.update!()
      Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, blocker.id})

      render_async(view)
      refute has_element?(view, "#issue-card-#{blocked.id} [data-qa='issue-blocked']")
    end

    test "blockers Linear fails to read leave the rows unmarked", %{conn: conn, insert: insert} do
      blocked = insert.("NST-7", %{})
      stub(Issues, :get_blockers, fn _issues -> raise "Linear is down" end)

      {:ok, view, _html} = live(conn, ~p"/issues")
      render_async(view)

      assert has_element?(view, "#issue-card-#{blocked.id}")
      refute has_element?(view, "[data-qa='issue-blocked']")
    end

    test "a GitHub project and All projects offer no cycle and ask nobody for one", %{
      conn: conn,
      github_project: github_project
    } do
      reject(&Issues.get_cycles/1)

      {:ok, view, _html} = live(conn, ~p"/issues")
      refute has_element?(view, "#cycle-toggle")

      {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: github_project.id}), ~p"/issues")
      refute has_element?(view, "#cycle-toggle")
    end
  end
end
