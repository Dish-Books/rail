defmodule RailWeb.OverviewLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.DetectedQuestion
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  test "redirects an unauthenticated user to the sign-in page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/")
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

  test "a task leaves without a reload when Linear deletes its issue, and stays when Linear archives it", %{
    conn: conn,
    project: project
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_live_removed",
        login: "overview_live_user_removed",
        email: "overview_live_user_removed@example.com",
        admin: true
      })

    user |> Ecto.Changeset.change(linear_user_id: "lin_usr_overview_removed") |> Repo.update!()
    {:ok, workspace} = Projects.get_linear_workspace(id: project.linear_workspace_id)

    [deleted_task, archived_task] =
      for external_id <- ["lin_overview_deleted", "lin_overview_archived"] do
        {:ok, task} =
          %Issue{}
          |> Issue.tracker_changeset(%{
            project_id: project.id,
            external_id: external_id,
            identifier: external_id,
            title: external_id,
            state: :in_progress,
            owner_user_id: user.id
          })
          |> Repo.insert!()
          |> Repo.preload(:project)
          |> Pipeline.create_task(:engineer)

        task
      end

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/")
    assert has_element?(view, "#in-progress-task-#{deleted_task.id}")
    assert has_element?(view, "#in-progress-task-#{archived_task.id}")

    assert {:ok, %Issue{}} =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Issue",
               "action" => "remove",
               "data" => %{"id" => "lin_overview_deleted"}
             })

    assert {:ok, %Issue{}} =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Issue",
               "action" => "update",
               "data" => %{
                 "id" => "lin_overview_archived",
                 "teamId" => "lin_team_id",
                 "identifier" => "lin_overview_archived",
                 "title" => "lin_overview_archived",
                 "assigneeId" => "lin_usr_overview_removed",
                 "state" => %{"id" => "st_in_progress", "name" => "In Progress", "type" => "started"},
                 "archivedAt" => "2026-10-06T10:00:00.000Z"
               }
             })

    refute has_element?(view, "#in-progress-task-#{deleted_task.id}")
    assert has_element?(view, "#in-progress-task-#{archived_task.id}")
  end

  test "a task or run read after its issue was deleted is left out, and the page still loads", %{
    conn: conn,
    project: project
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_live_half_deleted",
        login: "overview_live_user_half_deleted",
        email: "overview_live_user_half_deleted@example.com",
        admin: true
      })

    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)

    [{:ok, %{id: kept_id}}, {:ok, %{id: vanishing_id}}] =
      for external_id <- ["lin_overview_kept", "lin_overview_vanishing"] do
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: project.id,
          external_id: external_id,
          identifier: external_id,
          title: external_id,
          state: :in_progress,
          owner_user_id: user.id
        })
        |> Repo.insert!()
        |> Repo.preload(:project)
        |> Pipeline.create_task(:engineer)
      end

    {:ok, _run} =
      Pipeline.create_run(%{
        task_id: vanishing_id,
        role_id: engineer.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    # The task and its run were read, but the issue was deleted before their preloads ran.
    stub(Pipeline, :list_tasks, fn opts ->
      Pipeline
      |> Mimic.call_original(:list_tasks, [opts])
      |> Enum.map(&if(&1.id == vanishing_id, do: %{&1 | issue: nil}, else: &1))
    end)

    stub(Pipeline, :list_runs, fn opts ->
      Pipeline
      |> Mimic.call_original(:list_runs, [opts])
      |> Enum.map(&if(&1.task_id == vanishing_id, do: put_in(&1.task.issue, nil), else: &1))
    end)

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/")
    assert has_element?(view, "#in-progress-task-#{kept_id}")
    refute has_element?(view, "#in-progress-task-#{vanishing_id}")
  end

  test "project switcher displays active projects count and sends a pick to be stored", %{
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
               key: "P1",
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
               key: "P2",
               default_branch: "main",
               clone_path: "/tmp/p2",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    assert {:ok, view, _html} = live(authed_conn, ~p"/")

    # Initial state: All projects
    assert has_element?(view, "#selected-project-name", "All projects")
    assert has_element?(view, "#active-project-count", "4")
    refute has_element?(view, "#project-switcher-dialog")

    # Open project switcher
    view |> element("#project-switcher-button") |> render_click()
    assert has_element?(view, "#project-switcher-dialog")
    assert has_element?(view, "#project-option-#{p1_id}", p1_name)
    assert has_element?(view, "#project-option-#{p2_id}", p2_name)

    view |> element("#project-option-#{p1_id}") |> render_click()
    assert_redirect(view, ~p"/project-selection?#{[project_id: p1_id, return_to: "/"]}")

    assert {:ok, view, _html} = live(init_test_session(authed_conn, %{selected_project_id: p1_id}), ~p"/")
    assert has_element?(view, "#selected-project-name", p1_name)

    view |> element("#project-switcher-button") |> render_click()
    view |> element("#project-option-all") |> render_click()
    assert_redirect(view, ~p"/project-selection?#{[project_id: "", return_to: "/"]}")
  end

  test "the selected project sets current_project_id", %{conn: conn} do
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
               key: "PRE",
               default_branch: "main",
               clone_path: "/tmp/preset",
               active: true,
               linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
             })

    assert {:ok, view, _html} = live(init_test_session(authed_conn, %{selected_project_id: project_id}), ~p"/")
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

  test "the project switcher closes on Escape or a click outside it", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_live_8",
        login: "overview_live_user_8",
        email: "overview_live_user_8@example.com",
        admin: true
      })

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/")

    # Closed, it has nothing to close, so a click anywhere sends nothing.
    refute has_element?(view, "#project-switcher[phx-click-away]")

    view |> element("#project-switcher-button") |> render_click()

    # The button sits inside, so clicking it again toggles the dialog shut rather
    # than closing it and reopening it.
    assert has_element?(view, "#project-switcher[phx-click-away='close_project_switcher']")
    assert has_element?(view, "#project-switcher-dialog[phx-key='Escape']")

    view |> element("#project-switcher-dialog") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, "#project-switcher-dialog")
  end

  describe "the overview, which reads runs and the tasks they belong to" do
    setup %{conn: conn, project: project} do
      {:ok, user} =
        Users.register_oauth_user(%{
          github_id: "gh_overview_queue",
          login: "overview_queue_user",
          email: "overview_queue_user@example.com",
          admin: true
        })

      roles =
        Map.new(Role.canonical_stages(), fn stage ->
          {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)
          {stage, role}
        end)

      {:ok, rival} =
        Users.register_oauth_user(%{
          github_id: "gh_overview_rival",
          login: "overview_rival_user",
          email: "overview_rival_user@example.com"
        })

      # Each issue created answers Linear once, under a key of its own. A
      # `:completed_at` is Linear completing the issue. Issues belong to the
      # signed-in user unless `:owner_user_id` says otherwise.
      task_for = fn title, attrs ->
        {completed_at, attrs} = Map.pop(attrs, :completed_at)
        {owner_user_id, attrs} = Map.pop(attrs, :owner_user_id, user.id)
        {task_project, attrs} = Map.pop(attrs, :project, project)
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

        {:ok, issue} = Issues.create_issue(system_scope(), task_project, %{description: title})

        issue =
          issue
          |> Issue.tracker_changeset(%{completed_at: completed_at, owner_user_id: owner_user_id})
          |> Repo.update!()

        {:ok, task} = Pipeline.create_task(issue, :plan)
        {:ok, task} = Pipeline.update_task(task, attrs)
        Repo.preload(task, :issue)
      end

      %{conn: log_in_user(conn, user), user: user, project: project, roles: roles, rival: rival, task_for: task_for}
    end

    test "a child blocked by a canceled sibling is in Up next and counted as waiting on its owner", %{
      conn: conn,
      user: user,
      project: project
    } do
      for {identifier, title} <- [{"OVB-1", "Work on OVB-1"}, {"OVB-2", "Child OVB-2"}, {"OVB-3", "Child OVB-3"}] do
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

      {:ok, parent_issue} =
        Issues.create_issue(system_scope(), project, %{title: "Work on OVB-1", owner_user_id: user.id})

      {:ok, parent} = Pipeline.create_task(parent_issue, :split)
      parent = Repo.preload(parent, [:issue, :project])

      [first, blocked] =
        for {{identifier, builds_on}, number} <- Enum.with_index([{"OVB-2", []}, {"OVB-3", [1]}], 1) do
          attrs = %{title: "Child #{identifier}", parent: parent_issue, owner_user_id: user.id}
          {:ok, issue} = Issues.create_issue(system_scope(), project, attrs)
          part = %{number: number, builds_on: builds_on, plan: "## Implementation plan\n\nPart #{number}."}
          {:ok, child} = Pipeline.create_child_task(parent, issue, part)
          Repo.preload(child, [:issue, :project])
        end

      first.issue |> Issue.tracker_changeset(%{state: :canceled}) |> Repo.update!()

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(
               view,
               "#up-next-blocked-#{blocked.id}[href='/tasks/#{parent.id}?child=OVB-3']",
               "OVB-2 was canceled, so this will not start"
             )

      assert has_element?(view, "#up-next-blocked-#{blocked.id}", "in OVB-1")
      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "1")
      refute has_element?(view, "#up-next-empty")
    end

    test "someone else's split says its children need attention, not you, in Everyone", %{
      conn: conn,
      rival: rival,
      project: project,
      roles: roles
    } do
      for {identifier, title} <- [{"OVR-1", "Work on OVR-1"}, {"OVR-2", "Child OVR-2"}, {"OVR-3", "Child OVR-3"}] do
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

      {:ok, parent_issue} =
        Issues.create_issue(system_scope(), project, %{title: "Work on OVR-1", owner_user_id: rival.id})

      {:ok, parent} = Pipeline.create_task(parent_issue, :split)
      parent = Repo.preload(parent, [:issue, :project])

      children =
        for {{identifier, builds_on}, number} <- Enum.with_index([{"OVR-2", []}, {"OVR-3", []}], 1) do
          attrs = %{title: "Child #{identifier}", parent: parent_issue, owner_user_id: rival.id}
          {:ok, issue} = Issues.create_issue(system_scope(), project, attrs)
          part = %{number: number, builds_on: builds_on, plan: "## Implementation plan\n\nPart #{number}."}
          {:ok, child} = Pipeline.create_child_task(parent, issue, part)
          Repo.preload(child, [:issue, :project])
        end

      assert {:ok, view, _html} = live(conn, ~p"/?everyone=true")
      assert has_element?(view, "#in-progress-task-#{parent.id}", "Plan approved")

      for child <- children do
        {:ok, _failed} =
          Pipeline.create_run(%{
            task_id: child.id,
            role_id: roles[:engineer].id,
            status: :failed,
            error: "It broke.",
            started_at: DateTime.utc_now()
          })
      end

      assert {:ok, view, _html} = live(conn, ~p"/?everyone=true")

      assert has_element?(view, "#in-progress-task-#{parent.id}", "2 need attention")
      refute has_element?(view, "#in-progress-task-#{parent.id}", "need you")
      refute has_element?(view, "#in-progress-task-#{parent.id}[class*='amber']")
    end

    test "cleaning up a split parent takes its children out of In progress with it", %{
      conn: conn,
      user: user,
      project: project
    } do
      for {identifier, title} <- [{"OVC-1", "Work on OVC-1"}, {"OVC-2", "Child OVC-2"}, {"OVC-3", "Child OVC-3"}] do
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

      {:ok, parent_issue} =
        Issues.create_issue(system_scope(), project, %{title: "Work on OVC-1", owner_user_id: user.id})

      {:ok, parent} = Pipeline.create_task(parent_issue, :split)
      parent = Repo.preload(parent, [:issue, :project])

      [_first, _second] =
        for {{identifier, builds_on}, number} <- Enum.with_index([{"OVC-2", []}, {"OVC-3", [1]}], 1) do
          attrs = %{title: "Child #{identifier}", parent: parent_issue, owner_user_id: user.id}
          {:ok, issue} = Issues.create_issue(system_scope(), project, attrs)
          part = %{number: number, builds_on: builds_on, plan: "## Implementation plan\n\nPart #{number}."}
          {:ok, child} = Pipeline.create_child_task(parent, issue, part)
          Repo.preload(child, [:issue, :project])
        end

      {:ok, _cleaned} = Pipeline.cleanup_task(parent)

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#in-progress-count", "0 tasks")
      refute has_element?(view, "#in-progress-task-#{parent.id}")
    end

    test "a split parent is in progress once, a mark per child, its children waiting on the user in Up next", %{
      conn: conn,
      user: user,
      project: project,
      roles: roles
    } do
      now = DateTime.utc_now()

      for {identifier, title} <- [
            {"OVS-1", "Work on OVS-1"},
            {"OVS-2", "Child OVS-2"},
            {"OVS-3", "Child OVS-3"},
            {"OVS-4", "Child OVS-4"}
          ] do
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

      {:ok, parent_issue} =
        Issues.create_issue(system_scope(), project, %{title: "Work on OVS-1", owner_user_id: user.id})

      {:ok, parent} = Pipeline.create_task(parent_issue, :split)
      parent = Repo.preload(parent, [:issue, :project])

      [first, second, third] =
        for {{identifier, builds_on}, number} <- Enum.with_index([{"OVS-2", []}, {"OVS-3", [1]}, {"OVS-4", []}], 1) do
          attrs = %{title: "Child #{identifier}", parent: parent_issue, owner_user_id: user.id}
          {:ok, issue} = Issues.create_issue(system_scope(), project, attrs)
          part = %{number: number, builds_on: builds_on, plan: "## Implementation plan\n\nPart #{number}."}
          {:ok, child} = Pipeline.create_child_task(parent, issue, part)
          Repo.preload(child, [:issue, :project])
        end

      Repo.insert!(%ImplementationPlan{task_id: parent.id, content: "## Implementation plan", captured_at: now})

      {:ok, _done} =
        Pipeline.create_run(%{
          task_id: first.id,
          role_id: roles[:engineer].id,
          status: :finished,
          stage_outcome: :done,
          started_at: now
        })

      {:ok, _failed} =
        Pipeline.create_run(%{
          task_id: third.id,
          role_id: roles[:engineer].id,
          status: :failed,
          error: "It broke.",
          started_at: now
        })

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#in-progress-count", "1 task")
      assert has_element?(view, "#in-progress-task-#{parent.id}[href='/tasks/#{parent.id}']", "2 need you")
      assert has_element?(view, "#in-progress-task-#{parent.id}", "0 of 3 merged")

      assert has_element?(
               view,
               "#in-progress-task-#{parent.id} [data-qa='in-progress-child'][title='OVS-3: Waiting on OVS-2']"
             )

      assert view |> render() |> Floki.parse_document!() |> Floki.find("[data-qa='in-progress-child']") |> length() == 3
      assert has_element?(view, "#in-progress-task-#{parent.id}[class*='amber']")

      for child <- [first, second, third], do: refute(has_element?(view, "#in-progress-task-#{child.id}"))

      assert has_element?(view, "#up-next", "in OVS-1")
      assert has_element?(view, "#activity-feed", "OVS-1 split into 3")

      # A child deleted in Linear does not shrink the split the person approved.
      {:ok, workspace} = Projects.get_linear_workspace(id: project.linear_workspace_id)
      remove = %{"type" => "Issue", "action" => "remove", "data" => %{"id" => second.issue.external_id}}
      assert {:ok, _removed} = Issues.handle_linear_webhook(workspace, remove)

      assert {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#activity-feed", "OVS-1 split into 3")
    end

    test "opens on the user's own work, and switches to everyone's and back", %{
      conn: conn,
      roles: roles,
      rival: rival,
      task_for: task_for
    } do
      now = DateTime.utc_now()

      tasks = [
        task_for.("My first task", %{}),
        task_for.("My second task", %{}),
        task_for.("Their task", %{owner_user_id: rival.id}),
        task_for.("Unowned task", %{owner_user_id: nil})
      ]

      # Started over a day ago, so the feed holds only each run's handoff.
      [mine_one, mine_two, theirs, unowned] =
        for task <- tasks do
          {:ok, run} =
            Pipeline.create_run(%{
              task_id: task.id,
              role_id: roles[:plan].id,
              status: :finished,
              stage_outcome: :done,
              started_at: DateTime.shift(now, day: -2),
              completed_at: DateTime.shift(now, hour: -1)
            })

          run
        end

      my_shipped = task_for.("My shipped task", %{completed_at: DateTime.shift(now, hour: -2)})

      their_shipped =
        task_for.("Their shipped task", %{owner_user_id: rival.id, completed_at: DateTime.shift(now, hour: -2)})

      unowned_shipped =
        task_for.("Unowned shipped task", %{owner_user_id: nil, completed_at: DateTime.shift(now, hour: -2)})

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#overview-view-mine[aria-pressed='true']")
      assert has_element?(view, "#stat-in-progress [data-qa='stat-value']", "2")
      assert has_element?(view, "#stat-shipped [data-qa='stat-value']", "1")
      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "2")
      assert has_element?(view, "#throughput-total", "1 total")

      for run <- [mine_one, mine_two] do
        assert has_element?(view, "#up-next [href^='/tasks/#{run.task_id}']")
        assert has_element?(view, "#activity-ended-#{run.id}")
      end

      for run <- [theirs, unowned] do
        refute has_element?(view, "#up-next [href^='/tasks/#{run.task_id}']")
        refute has_element?(view, "#activity-ended-#{run.id}")
      end

      assert has_element?(view, "#activity-shipped-#{my_shipped.issue.id}")
      refute has_element?(view, "#activity-shipped-#{their_shipped.issue.id}")
      refute has_element?(view, "#activity-shipped-#{unowned_shipped.issue.id}")

      view |> element("#overview-view-everyone") |> render_click()
      assert_patched(view, ~p"/?everyone=true")

      assert has_element?(view, "#overview-view-everyone[aria-pressed='true']")
      assert has_element?(view, "#stat-in-progress [data-qa='stat-value']", "4")
      assert has_element?(view, "#stat-shipped [data-qa='stat-value']", "3")
      # Waiting on you stays the user's own; Up next below follows the view.
      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "2")
      assert has_element?(view, "#throughput-total", "3 total")

      for run <- [mine_one, mine_two, theirs, unowned] do
        assert has_element?(view, "#up-next [href^='/tasks/#{run.task_id}']")
        assert has_element?(view, "#activity-ended-#{run.id}")
      end

      assert has_element?(view, "#activity-shipped-#{their_shipped.issue.id}")
      assert has_element?(view, "#activity-shipped-#{unowned_shipped.issue.id}")

      view |> element("#overview-view-mine") |> render_click()
      assert_patched(view, ~p"/")

      assert has_element?(view, "#stat-in-progress [data-qa='stat-value']", "2")
      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "2")
    end

    test "with a project picked, both views keep to that project", %{
      conn: conn,
      project: project,
      rival: rival,
      task_for: task_for
    } do
      task_for.("My task", %{})
      task_for.("Their task", %{owner_user_id: rival.id})
      task_for.("Unowned task", %{owner_user_id: nil})

      assert {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: project.id}), ~p"/")

      assert has_element?(view, "#stat-in-progress [data-qa='stat-value']", "1")

      view |> element("#overview-view-everyone") |> render_click()
      assert_patched(view, ~p"/?everyone=true")

      assert has_element?(view, "#selected-project-name", project.name)
      assert has_element?(view, "#stat-in-progress [data-qa='stat-value']", "3")
    end

    test "a user who owns nothing sees nothing of the team's until they switch", %{
      conn: conn,
      roles: roles,
      rival: rival,
      task_for: task_for
    } do
      now = DateTime.utc_now()
      theirs = task_for.("Their task", %{owner_user_id: rival.id})

      {:ok, run} =
        Pipeline.create_run(%{
          task_id: theirs.id,
          role_id: roles[:plan].id,
          status: :finished,
          stage_outcome: :done,
          started_at: DateTime.shift(now, hour: -2),
          completed_at: DateTime.shift(now, hour: -1)
        })

      task_for.("Their shipped task", %{owner_user_id: rival.id, completed_at: DateTime.shift(now, hour: -1)})
      task_for.("Unowned task", %{owner_user_id: nil})

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#stat-in-progress [data-qa='stat-value']", "0")
      assert has_element?(view, "#stat-shipped [data-qa='stat-value']", "0")
      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "0")
      assert has_element?(view, "#up-next-empty")
      assert has_element?(view, "#activity-feed-empty")
      assert has_element?(view, "#throughput-total", "0 total")

      view |> element("#overview-view-everyone") |> render_click()

      assert has_element?(view, "#stat-in-progress [data-qa='stat-value']", "2")
      assert has_element?(view, "#stat-shipped [data-qa='stat-value']", "1")
      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "0")
      refute has_element?(view, "#stat-oldest-waiting")
      assert has_element?(view, "#up-next [href^='/tasks/#{theirs.id}']")
      assert has_element?(view, "#activity-ended-#{run.id}")
      assert has_element?(view, "#throughput-total", "1 total")
    end

    test "waiting on you counts and dates only the user's own work, while up next follows the view", %{
      conn: conn,
      roles: roles,
      rival: rival,
      task_for: task_for
    } do
      now = DateTime.utc_now()
      mine = task_for.("My waiting task", %{})
      theirs = task_for.("Their older waiting task", %{owner_user_id: rival.id})
      unowned = task_for.("Unowned older waiting task", %{owner_user_id: nil})

      for {task, hours} <- [{mine, 1}, {theirs, 5}, {unowned, 7}] do
        {:ok, _run} =
          Pipeline.create_run(%{
            task_id: task.id,
            role_id: roles[:plan].id,
            status: :finished,
            stage_outcome: :done,
            started_at: DateTime.shift(now, hour: -(hours + 1)),
            completed_at: DateTime.shift(now, hour: -hours)
          })
      end

      assert {:ok, view, _html} = live(conn, ~p"/?everyone=true")

      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "1")
      assert has_element?(view, "#stat-oldest-waiting", "oldest 1h 0m")

      for task <- [mine, theirs, unowned] do
        assert has_element?(view, "#up-next [href^='/tasks/#{task.id}']")
      end
    end

    test "picking a project in the switcher keeps everyone's view", %{conn: conn, project: project} do
      assert {:ok, view, _html} = live(conn, ~p"/?everyone=true")

      view |> element("#project-switcher-button") |> render_click()
      view |> element("#project-option-#{project.id}") |> render_click()
      assert_redirect(view, ~p"/project-selection?#{[project_id: project.id, return_to: "/?everyone=true"]}")

      assert {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: project.id}), ~p"/?everyone=true")
      assert has_element?(view, "#selected-project-name", project.name)
      assert has_element?(view, "#overview-view-everyone[aria-pressed='true']")

      view |> element("#project-switcher-button") |> render_click()
      view |> element("#project-option-all") |> render_click()
      assert_redirect(view, ~p"/project-selection?#{[project_id: "", return_to: "/?everyone=true"]}")
    end

    test "picking a project from my own work returns to my own work", %{conn: conn, project: project} do
      assert {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#project-switcher-button") |> render_click()
      view |> element("#project-option-#{project.id}") |> render_click()
      assert_redirect(view, ~p"/project-selection?#{[project_id: project.id, return_to: "/"]}")
    end

    test "the chosen view is the link, so a reload or a shared link opens on it", %{
      conn: conn,
      rival: rival,
      task_for: task_for
    } do
      task_for.("My task", %{})
      task_for.("Their task", %{owner_user_id: rival.id})

      assert {:ok, view, _html} = live(conn, ~p"/?everyone=true")

      assert has_element?(view, "#overview-view-everyone[aria-pressed='true']")
      assert has_element?(view, "#overview-view-mine[aria-pressed='false']")
      assert has_element?(view, "#stat-in-progress [data-qa='stat-value']", "2")

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#overview-view-mine[aria-pressed='true']")
      assert has_element?(view, "#overview-view-everyone[aria-pressed='false']")
      assert has_element?(view, "#stat-in-progress [data-qa='stat-value']", "1")
    end

    test "the in-progress list follows the view, and counts what the stat counts", %{
      conn: conn,
      roles: roles,
      rival: rival,
      task_for: task_for
    } do
      mine = task_for.("My task", %{})
      theirs = task_for.("Their running task", %{owner_user_id: rival.id, stage: :engineer})

      {:ok, _run} =
        Pipeline.create_run(%{
          task_id: theirs.id,
          role_id: roles[:engineer].id,
          status: :running,
          started_at: DateTime.shift(DateTime.utc_now(), minute: -10)
        })

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#in-progress-task-#{mine.id}")
      refute has_element?(view, "#in-progress-task-#{theirs.id}")
      assert has_element?(view, "#in-progress-count", ~r/^\s*1 task\s*$/)
      assert has_element?(view, "#stat-in-progress [data-qa='stat-value']", "1")

      view |> element("#overview-view-everyone") |> render_click()

      assert has_element?(view, "#in-progress-task-#{mine.id}")
      assert has_element?(view, "#in-progress-task-#{theirs.id}", "Engineer running")
      assert has_element?(view, "#in-progress-count", "2 tasks")
      assert has_element?(view, "#stat-in-progress [data-qa='stat-value']", "2")
    end

    test "in everyone's view, only the user's own handed-off work reads as waiting on them", %{
      conn: conn,
      roles: roles,
      rival: rival,
      task_for: task_for
    } do
      now = DateTime.utc_now()
      theirs = task_for.("Their plan", %{owner_user_id: rival.id, stage: :plan})
      mine = task_for.("My plan", %{stage: :plan})

      for task <- [theirs, mine] do
        {:ok, _run} =
          Pipeline.create_run(%{
            task_id: task.id,
            role_id: roles[:plan].id,
            status: :finished,
            stage_outcome: :done,
            started_at: DateTime.shift(now, hour: -2),
            completed_at: DateTime.shift(now, hour: -1)
          })
      end

      assert {:ok, view, _html} = live(conn, ~p"/?everyone=true")

      assert has_element?(view, "#in-progress-task-#{theirs.id}[data-state='done']", "Review the plan")
      refute has_element?(view, "#in-progress-task-#{theirs.id}.bg-amber-50")
      assert has_element?(view, "#in-progress-task-#{mine.id}.bg-amber-50", "Review the plan")
    end

    test "with nothing going on, nothing waits and nothing is in progress", %{conn: conn, project: project} do
      assert {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: project.id}), ~p"/")

      assert has_element?(view, "#stat-in-progress [data-qa='stat-value']", "0")
      assert has_element?(view, "#stat-shipped-delta", "same as prior 30")
      refute has_element?(view, "#stat-oldest-waiting")
      assert has_element?(view, "#up-next-empty", "Nothing is waiting on you.")
      assert has_element?(view, "#activity-feed-empty")
      assert has_element?(view, "#in-progress-empty", "Nothing is in progress.")
      assert has_element?(view, "#in-progress-count", "0 tasks")
      refute has_element?(view, "#role-roster")
      refute has_element?(view, "[data-qa='role-row']")
      refute has_element?(view, "#roster-running-count")
      assert has_element?(view, "#throughput-total", "0 total")
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
          role_id: roles[:plan].id,
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

      # Unfiltered, the list names the project each group of tasks belongs to.
      assert has_element?(view, "[data-qa='in-progress-project-header']", "Test Project")
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
          role_id: roles[:plan].id,
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

        Enum.each(prompts, fn prompt ->
          {:ok, _question} =
            Pipeline.register_question(Repo.preload(run, task: :issue), %DetectedQuestion{prompt: prompt})
        end)

        {:ok, blocked} = Pipeline.get_run(run.id)
        {:ok, stopped} = Pipeline.update_run(blocked, %{completed_at: stopped_at})
        {task, stopped}
      end

      {one_task, one_question} =
        blocked_run.("Naming decision", roles[:plan], ["Which name?"], DateTime.shift(now, hour: -2))

      {two_task, two_questions} =
        blocked_run.("Two decisions", roles[:engineer], ["Which db?", "Behind a flag?"], DateTime.shift(now, hour: -1))

      assert {:ok, view, html} = live(conn, ~p"/")

      assert has_element?(view, "#up-next-featured-#{review_run.id}[href='/tasks/#{review.id}']", "Ticket to review")
      assert has_element?(view, "#up-next-featured-#{review_run.id} [data-qa='up-next-chip']", "Ready for review")
      assert has_element?(view, "#up-next-featured-#{review_run.id}", "Review the plan")

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
      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "3")
      assert has_element?(view, "#attention-badge", "3")

      assert has_element?(view, "#activity-ended-#{review_run.id}", "is ready for review")
      assert has_element?(view, "#activity-asked-#{one_question.id}", "asked a question")
      assert has_element?(view, "#activity-asked-#{two_questions.id}", "asked 2 questions")
    end

    test "a task at Plan with options unpicked waits once, on the pick, and the run it took over is done with it", %{
      conn: conn,
      roles: roles,
      task_for: task_for
    } do
      now = DateTime.utc_now()
      task = task_for.("Warn on duplicate bills", %{stage: :plan})
      design_dir = Path.join(task.scratch_path, "design")
      File.mkdir_p!(design_dir)
      on_exit(fn -> File.rm_rf(task.scratch_path) end)

      File.write!(
        Path.join(design_dir, "manifest.json"),
        ~s({"options": [{"key": "a", "title": "A"}, {"key": "b", "title": "B"}, {"key": "c", "title": "C"}]})
      )

      {:ok, design_run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:design].id,
          status: :finished,
          stage_outcome: :done,
          started_at: DateTime.shift(now, hour: -5),
          completed_at: DateTime.shift(now, hour: -4)
        })

      {:ok, plan_run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:plan].id,
          status: :finished,
          stage_outcome: :done,
          started_at: DateTime.shift(now, hour: -2),
          completed_at: DateTime.shift(now, hour: -1)
        })

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#up-next-featured-#{plan_run.id}", "#{task.issue.identifier} · plan role")
      assert has_element?(view, "#up-next-featured-#{plan_run.id}", "Pick a design")

      assert has_element?(
               view,
               "#up-next-featured-#{plan_run.id} [data-qa='up-next-summary']",
               "Waiting on you to pick a design."
             )

      refute has_element?(view, "#up-next-featured-#{design_run.id}")
      refute has_element?(view, "#up-next-row-#{design_run.id}")
      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "1")

      assert has_element?(view, "#in-progress-task-#{task.id}[data-state='done']", "Pick a design")
      assert has_element?(view, "#in-progress-task-#{task.id} [data-qa='in-progress-age']", "1h 0m")
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
          role_id: roles[:plan].id,
          status: :running,
          conversation_id: "sess_answered",
          started_at: DateTime.utc_now()
        })

      {:ok, question} =
        Pipeline.register_question(Repo.preload(run, task: :issue), %DetectedQuestion{prompt: "Which one?"})

      {:ok, _answered} = Pipeline.answer_question(system_scope(), question, "That one")

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
          role_id: roles[:plan].id,
          status: :running,
          conversation_id: "sess_pending",
          started_at: DateTime.utc_now()
        })

      {:ok, _question} =
        Pipeline.register_question(Repo.preload(run, task: :issue), %DetectedQuestion{prompt: "Which database?"})

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#up-next-featured-#{run.id} [data-qa='up-next-summary']", "Which database?")
    end

    test "since yesterday lists what runs did and what shipped, newest first", %{
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

      failed_task = task_for.("Failed work", %{stage: :review})

      {:ok, failed} =
        Pipeline.create_run(%{
          task_id: failed_task.id,
          role_id: roles[:review_lead].id,
          status: :failed,
          error: "Exited with code 2",
          started_at: DateTime.shift(now, hour: -5),
          completed_at: DateTime.shift(now, hour: -4)
        })

      # A stage no human signs off just finished; it did not hand anything over.
      gate_task = task_for.("Gate work", %{stage: :debugger})

      {:ok, gate} =
        Pipeline.create_run(%{
          task_id: gate_task.id,
          role_id: roles[:debugger].id,
          status: :finished,
          stage_outcome: :done,
          started_at: DateTime.shift(now, hour: -5),
          completed_at: DateTime.shift(now, hour: -4)
        })

      stopped_task = task_for.("Stopped work", %{stage: :plan})

      {:ok, stopped} =
        Pipeline.create_run(%{
          task_id: stopped_task.id,
          role_id: roles[:plan].id,
          status: :finished,
          started_at: DateTime.shift(now, hour: -4),
          completed_at: DateTime.shift(now, hour: -3)
        })

      moved_on = task_for.("Moved on work", %{stage: :engineer})

      {:ok, finished} =
        Pipeline.create_run(%{
          task_id: moved_on.id,
          role_id: roles[:plan].id,
          status: :finished,
          stage_outcome: :done,
          started_at: DateTime.shift(now, hour: -3),
          completed_at: DateTime.shift(now, hour: -2)
        })

      shipped = task_for.("Shipped work", %{completed_at: DateTime.shift(now, hour: -1)})

      old_task = task_for.("Old work", %{stage: :plan})

      {:ok, old} =
        Pipeline.create_run(%{
          task_id: old_task.id,
          role_id: roles[:plan].id,
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
      assert has_element?(view, "#activity-ended-#{gate.id}", "finished on")
      # A product run reads as the handoff it was, whether or not the ticket has
      # since been approved and the task moved on.
      assert has_element?(view, "#activity-ended-#{finished.id}", "is ready for review")
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

      # Only a run at the task's own stage says where it stands, not the Plan
      # run it moved on from.
      assert has_element?(view, "#in-progress-task-#{moved_on.id}[data-state='queued']", "Queued for Engineer")

      # Of two tasks that broke, the one broken longest comes first.
      assert html |> :binary.match("in-progress-task-#{old_task.id}") |> elem(0) <
               html |> :binary.match("in-progress-task-#{failed_task.id}") |> elem(0)
    end

    test "a merged task waits on nobody and is not in progress", %{conn: conn, roles: roles, task_for: task_for} do
      task = task_for.("Shipped work", %{stage: :merged, merged_at: DateTime.utc_now()})
      completed = task_for.("Completed in Linear", %{completed_at: DateTime.utc_now()})
      live_task = task_for.("Live work", %{})

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

      refute has_element?(view, "#in-progress-task-#{task.id}")
      refute has_element?(view, "#in-progress-task-#{completed.id}")
      assert has_element?(view, "#in-progress-task-#{live_task.id}")
      assert has_element?(view, "#in-progress-count", ~r/^\s*1 task\s*$/)
      assert has_element?(view, "#stat-in-progress [data-qa='stat-value']", "1")
    end

    test "a stage that failed and is running again waits on nobody", %{
      conn: conn,
      roles: roles,
      task_for: task_for
    } do
      now = DateTime.utc_now()
      task = task_for.("Retry after failure", %{stage: :review})

      {:ok, failed} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:review_lead].id,
          status: :failed,
          error: "3 of 11 checks failed",
          started_at: DateTime.shift(now, hour: -2),
          completed_at: DateTime.shift(now, hour: -1)
        })

      {:ok, _retry} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:review_lead].id,
          status: :running,
          started_at: DateTime.shift(now, minute: -10)
        })

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#up-next-empty")
      refute has_element?(view, "#up-next-featured-#{failed.id}")
      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "0")
      refute has_element?(view, "#attention-badge")
      assert has_element?(view, "#in-progress-task-#{task.id}[data-state='running']", "Review running")
    end

    test "a Review run whose review is finished leads as ready to merge", %{
      conn: conn,
      roles: roles,
      task_for: task_for
    } do
      task =
        task_for.("Finished review", %{
          stage: :review,
          pr_number: 4,
          pr_url: "https://github.com/example/test-seed/pull/4"
        })

      on_exit(fn -> File.rm_rf(task.scratch_path) end)

      {:ok, %Run{id: run_id} = run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:review_lead].id,
          status: :finished,
          stage_outcome: :done,
          started_at: DateTime.shift(DateTime.utc_now(), hour: -1),
          completed_at: DateTime.utc_now()
        })

      {:ok, _pass} = Pipeline.save_review(task)

      assert {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#up-next-featured-#{run_id} [data-qa='up-next-chip']", "Ready for review")
      assert has_element?(view, "#in-progress-task-#{task.id}", "Review the findings")

      {:ok, %Run{id: ^run_id}} = Pipeline.start_fix_round(run)

      assert {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#up-next-featured-#{run_id} [data-qa='up-next-chip']", "Ready to merge")
      assert has_element?(view, "#in-progress-task-#{task.id}", "Ready to merge")
    end

    test "the sidebar lists every task in progress and where it stands", %{
      conn: conn,
      roles: roles,
      task_for: task_for
    } do
      now = DateTime.utc_now()
      engineer = task_for.("Retry backs off", %{stage: :engineer})

      {:ok, _running} =
        Pipeline.create_run(%{
          task_id: engineer.id,
          role_id: roles[:engineer].id,
          status: :running,
          started_at: DateTime.shift(now, hour: -4)
        })

      architect = task_for.("Prorate seat changes", %{stage: :plan})

      {:ok, _done} =
        Pipeline.create_run(%{
          task_id: architect.id,
          role_id: roles[:plan].id,
          status: :finished,
          stage_outcome: :done,
          started_at: DateTime.shift(now, hour: -3),
          completed_at: DateTime.shift(now, hour: -2)
        })

      review = task_for.("Retry a failed Review run", %{stage: :review})

      {:ok, _failed} =
        Pipeline.create_run(%{
          task_id: review.id,
          role_id: roles[:review_lead].id,
          status: :failed,
          error: "3 of 11 checks failed",
          started_at: DateTime.shift(now, hour: -2),
          completed_at: DateTime.shift(now, hour: -1)
        })

      assert {:ok, view, html} = live(conn, ~p"/")

      assert has_element?(view, "#in-progress-task-#{engineer.id}[data-state='running']", "Engineer running")
      assert has_element?(view, "#in-progress-task-#{engineer.id} [data-qa='in-progress-age']", "4h 0m")
      assert has_element?(view, "#in-progress-task-#{architect.id}[data-state='done']", "Review the plan")
      assert has_element?(view, "#in-progress-task-#{architect.id}", "Prorate seat changes")
      assert has_element?(view, "#in-progress-task-#{architect.id}", architect.issue.identifier)
      assert has_element?(view, "#in-progress-task-#{review.id}[data-state='failed']", "Review failed")

      assert has_element?(view, "#in-progress-count", "3 tasks")
      assert has_element?(view, "#stat-in-progress [data-qa='stat-value']", "3")

      # Waiting on you first, then broken, then working, however long each has been so.
      positions =
        Enum.map([architect, review, engineer], fn task ->
          html |> :binary.match("in-progress-task-#{task.id}") |> elem(0)
        end)

      assert positions == Enum.sort(positions)

      refute has_element?(view, "#role-roster")
    end

    test "a run waiting for resources is counted, linked to the line, and is neither failed nor stopped", %{
      conn: conn,
      roles: roles,
      task_for: task_for
    } do
      now = DateTime.utc_now()
      engineer = task_for.("Recipe costs update", %{stage: :engineer})

      {:ok, run} =
        Pipeline.create_run(%{
          task_id: engineer.id,
          role_id: roles[:engineer].id,
          status: :waiting_for_resources,
          started_at: DateTime.shift(now, minute: -5)
        })

      Repo.insert!(%OsProcess{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/dev/null",
        status: :waiting_for_resources,
        started_at: now,
        queued_at: DateTime.shift(now, minute: -4),
        reserved_cpus: 2,
        reserved_memory_gb: 4
      })

      Repo.insert!(%OsProcess{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/dev/null",
        status: :running,
        started_at: now,
        reserved_cpus: 3,
        reserved_memory_gb: 2
      })

      assert {:ok, view, html} = live(conn, ~p"/")

      assert has_element?(view, "#stat-waiting-for-resources [data-qa='stat-value']", "1")
      assert has_element?(view, "#stat-waiting-for-resources[href='/sandboxes']", "oldest 4m")
      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "0")

      assert has_element?(
               view,
               "#in-progress-task-#{engineer.id}[data-state='waiting']",
               "Engineer waiting for resources"
             )

      assert has_element?(view, "#sandbox-meters #sandbox-meters-count", "1 running · 1 waiting")
      assert has_element?(view, "#sandbox-meter-cpus", "3 of 4")
      assert has_element?(view, "#sandbox-meter-cpus", "1 CPU free")
      assert has_element?(view, "#sandbox-meter-memory", "6 GB free")
      assert has_element?(view, "#open-sandboxes[href='/sandboxes']", "1 waiting · oldest 4m")

      # The machine comes before the tasks on it.
      assert elem(:binary.match(html, "sandbox-meters"), 0) < elem(:binary.match(html, "in-progress-tasks"), 0)
    end

    test "a machine whose capacity cannot be read shows no meters, and still counts the line", %{conn: conn} do
      stub(Rail.Tools, :get_sandbox_capacity, fn -> {:error, :econnrefused} end)

      assert {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#sandbox-meters")
      assert has_element?(view, "#stat-waiting-for-resources [data-qa='stat-value']", "0")
    end

    test "the list honors the project switcher", %{conn: conn, project: project, task_for: task_for} do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_other"}]}}})
      end)

      {:ok, other_project} =
        Projects.create_project(system_scope(), %{
          name: "Other Project",
          github_repo: "example/other",
          github_installation_id: 444,
          key: "OTH",
          default_branch: "main",
          clone_path: "/tmp/other",
          linear_workspace_id: project.linear_workspace_id
        })

      mine = task_for.("Work in this project", %{})
      theirs = task_for.("Work in the other project", %{project: other_project})

      assert {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: project.id}), ~p"/")

      assert has_element?(view, "#in-progress-task-#{mine.id}[data-state='queued']", "Queued for Plan")
      refute has_element?(view, "#in-progress-task-#{theirs.id}")
      refute has_element?(view, "[data-qa='in-progress-project-header']")
      assert has_element?(view, "#in-progress-count", ~r/^\s*1 task\s*$/)

      assert {:ok, view, html} = live(conn, ~p"/")

      assert has_element?(view, "#in-progress-task-#{mine.id}")
      assert has_element?(view, "#in-progress-task-#{theirs.id}")
      assert has_element?(view, "[data-qa='in-progress-project-header']", "Test Project")
      assert has_element?(view, "[data-qa='in-progress-project-header']", "Other Project")
      assert has_element?(view, "#in-progress-count", "2 tasks")
      assert has_element?(view, "#stat-in-progress [data-qa='stat-value']", "2")

      # Projects come in the switcher's order, by name.
      positions =
        Enum.map([theirs, mine], fn task -> html |> :binary.match("in-progress-task-#{task.id}") |> elem(0) end)

      assert positions == Enum.sort(positions)
    end

    test "a user granted one project sees its work in both views, other people's included, and none of another's", %{
      conn: conn,
      project: project,
      roles: roles,
      rival: rival,
      task_for: task_for
    } do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_other"}]}}})
      end)

      {:ok, other_project} =
        Projects.create_project(system_scope(), %{
          name: "Other Project",
          github_repo: "example/other",
          github_installation_id: 444,
          key: "OTH",
          default_branch: "main",
          clone_path: "/tmp/other",
          linear_workspace_id: project.linear_workspace_id
        })

      {:ok, other_role} =
        Roles.create_role(system_scope(), other_project, %{
          stage: :plan,
          name: "Other Product",
          model: "claude-opus-5-5",
          system_prompt: "You write tickets.",
          cli: :claude
        })

      {:ok, rival} = Users.update_user(system_scope(), rival, %{project_ids: [project.id]})
      now = DateTime.utc_now()

      own = task_for.("My work here", %{owner_user_id: rival.id})
      teammates = task_for.("A teammate's work here", %{})
      elsewhere = task_for.("My work elsewhere", %{owner_user_id: rival.id, project: other_project})
      hidden = task_for.("Someone's work elsewhere", %{project: other_project})

      shipped_elsewhere =
        task_for.("Shipped elsewhere", %{project: other_project, completed_at: DateTime.shift(now, hour: -2)})

      for {task, role} <- [{own, roles[:plan]}, {elsewhere, other_role}] do
        {:ok, _done} =
          Pipeline.create_run(%{
            task_id: task.id,
            role_id: role.id,
            status: :finished,
            stage_outcome: :done,
            started_at: DateTime.shift(now, hour: -2),
            completed_at: DateTime.shift(now, hour: -1)
          })
      end

      assert {:ok, view, _html} = live(log_in_user(conn, rival), ~p"/")

      assert has_element?(view, "#in-progress-task-#{own.id}")
      refute has_element?(view, "#in-progress-task-#{elsewhere.id}")
      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "1")
      assert has_element?(view, "#attention-badge", "1")

      view |> element("#overview-view-everyone") |> render_click()

      assert has_element?(view, "#in-progress-task-#{own.id}")
      assert has_element?(view, "#in-progress-task-#{teammates.id}")
      refute has_element?(view, "#in-progress-task-#{elsewhere.id}")
      refute has_element?(view, "#in-progress-task-#{hidden.id}")
      refute has_element?(view, "#activity-shipped-#{shipped_elsewhere.issue.id}")
      refute has_element?(view, "[data-qa='in-progress-project-header']", "Other Project")
      refute render(view) =~ "elsewhere"

      Phoenix.PubSub.broadcast(Rail.PubSub, "pipeline", {:pipeline_changed, own.id})
      assert has_element?(view, "#attention-badge", "1")

      assert {:ok, admin_view, _html} = live(conn, ~p"/?everyone=true")

      for task <- [own, teammates, elsewhere, hidden] do
        assert has_element?(admin_view, "#in-progress-task-#{task.id}")
      end

      assert has_element?(admin_view, "#activity-shipped-#{shipped_elsewhere.issue.id}")
      assert has_element?(admin_view, "#attention-badge", "2")
    end

    test "a row opens its task", %{conn: conn, task_for: task_for} do
      task = task_for.("Open me", %{})

      assert {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#in-progress-task-#{task.id}") |> render_click()
      assert_redirect(view, ~p"/tasks/#{task.id}")
    end

    test "a project that no longer exists lists nothing in progress", %{conn: conn} do
      assert {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: "prj_missing"}), ~p"/")

      assert has_element?(view, "#in-progress-empty")
    end

    test "a run that hands its work over is waiting on the user, without a reload", %{
      conn: conn,
      roles: roles,
      task_for: task_for
    } do
      now = DateTime.utc_now()
      task = task_for.("Handed over", %{stage: :engineer})

      {:ok, run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          status: :running,
          started_at: DateTime.shift(now, minute: -30)
        })

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "0")
      refute has_element?(view, "[id^='up-next-featured-']")
      assert has_element?(view, "#in-progress-task-#{task.id}[data-state='running']")

      {:ok, _finished} = Pipeline.update_run(run, %{status: :finished, stage_outcome: :done, completed_at: now})
      Phoenix.PubSub.broadcast(Rail.PubSub, "pipeline", {:pipeline_changed, task.id})

      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "1")
      assert has_element?(view, "#up-next-featured-#{run.id}[href='/tasks/#{task.id}']")
      assert has_element?(view, "#activity-ended-#{run.id}", "says #{task.issue.identifier} is ready for review")
      assert has_element?(view, "#in-progress-task-#{task.id}[data-state='done']")
    end

    test "a run that asks a question is waiting on the user, without a reload", %{
      conn: conn,
      roles: roles,
      task_for: task_for
    } do
      task = task_for.("Asks something", %{stage: :engineer})

      {:ok, run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          status: :running,
          conversation_id: "sess_asks_live",
          started_at: DateTime.utc_now()
        })

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "0")
      assert has_element?(view, "#in-progress-task-#{task.id}[data-state='running']")

      {:ok, _question} =
        Pipeline.register_question(Repo.preload(run, task: :issue), %DetectedQuestion{prompt: "Which database?"})

      Phoenix.PubSub.broadcast(Rail.PubSub, "pipeline", {:pipeline_changed, task.id})

      assert has_element?(view, "#in-progress-task-#{task.id}[data-state='blocked']")
      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "1")
    end

    test "a run that starts, then joins the sandbox line, shows as it goes, without a reload", %{
      conn: conn,
      roles: roles,
      task_for: task_for
    } do
      now = DateTime.utc_now()
      task = task_for.("Starts and queues", %{stage: :engineer})

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#in-progress-task-#{task.id}[data-state='queued']")

      {:ok, run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          status: :running,
          started_at: now
        })

      Phoenix.PubSub.broadcast(Rail.PubSub, "sandboxes", :sandboxes_changed)

      assert has_element?(view, "#in-progress-task-#{task.id}[data-state='running']")
      assert has_element?(view, "#stat-waiting-for-resources [data-qa='stat-value']", "0")

      {:ok, _waiting} = Pipeline.update_run(run, %{status: :waiting_for_resources})

      Repo.insert!(%OsProcess{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/dev/null",
        status: :waiting_for_resources,
        started_at: now,
        queued_at: now,
        reserved_cpus: 2,
        reserved_memory_gb: 4
      })

      Phoenix.PubSub.broadcast(Rail.PubSub, "sandboxes", :sandboxes_changed)

      assert has_element?(view, "#in-progress-task-#{task.id}[data-state='waiting']")
      assert has_element?(view, "#stat-waiting-for-resources [data-qa='stat-value']", "1")
    end

    test "a task whose issue Linear completes has shipped, without a reload", %{conn: conn, task_for: task_for} do
      task = task_for.("Ships in Linear", %{stage: :engineer})

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#in-progress-task-#{task.id}")
      assert has_element?(view, "#stat-shipped [data-qa='stat-value']", "0")
      assert has_element?(view, "#throughput-total", "0 total")

      task.issue |> Issue.tracker_changeset(%{completed_at: DateTime.utc_now()}) |> Repo.update!()
      Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, task.issue.id})

      refute has_element?(view, "#in-progress-task-#{task.id}")
      assert has_element?(view, "#stat-shipped [data-qa='stat-value']", "1")
      assert has_element?(view, "#throughput-total", "1 total")
      assert has_element?(view, "#activity-shipped-#{task.issue.id}", "#{task.issue.identifier} shipped")
    end

    test "a task that shipped while its run waited on the user waits on nobody", %{
      conn: conn,
      roles: roles,
      task_for: task_for
    } do
      task = task_for.("Failed then shipped", %{stage: :engineer})

      {:ok, run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          status: :failed,
          error: "Exited with code 2",
          started_at: DateTime.shift(DateTime.utc_now(), hour: -2),
          completed_at: DateTime.shift(DateTime.utc_now(), hour: -1)
        })

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#up-next-featured-#{run.id}")
      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "1")

      task.issue |> Issue.tracker_changeset(%{completed_at: DateTime.utc_now()}) |> Repo.update!()
      Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, task.issue.id})

      refute has_element?(view, "[id^='up-next-'][href^='/tasks/#{task.id}']")
      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "0")
      refute has_element?(view, "#attention-badge")
    end

    test "the rail's attention badge moves with the stats it sits beside", %{
      conn: conn,
      roles: roles,
      task_for: task_for
    } do
      task = task_for.("About to fail", %{stage: :engineer})

      {:ok, run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#attention-badge")

      {:ok, _failed} =
        Pipeline.update_run(run, %{status: :failed, error: "Exited with code 2", completed_at: DateTime.utc_now()})

      Phoenix.PubSub.broadcast(Rail.PubSub, "pipeline", {:pipeline_changed, task.id})

      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "1")
      assert has_element?(view, "#attention-badge", "1")
    end

    test "a task whose issue completes in a sync from Linear has shipped, without a reload", %{
      conn: conn,
      project: project,
      task_for: task_for
    } do
      task = task_for.("Ships in a sync", %{stage: :engineer})

      assert {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#in-progress-task-#{task.id}")

      task.issue |> Issue.tracker_changeset(%{completed_at: DateTime.utc_now()}) |> Repo.update!()
      Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issues_synced, project.id})

      refute has_element?(view, "#in-progress-task-#{task.id}")
      assert has_element?(view, "#stat-shipped [data-qa='stat-value']", "1")
    end

    test "on my work in one project, a change to someone else's task or another project's changes nothing", %{
      conn: conn,
      project: project,
      roles: roles,
      rival: rival,
      task_for: task_for
    } do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_other"}]}}})
      end)

      {:ok, other_project} =
        Projects.create_project(system_scope(), %{
          name: "Other Project",
          github_repo: "example/other",
          github_installation_id: 444,
          key: "OTH",
          default_branch: "main",
          clone_path: "/tmp/other",
          linear_workspace_id: project.linear_workspace_id
        })

      mine = task_for.("My work here", %{})
      theirs = task_for.("Their work here", %{owner_user_id: rival.id, stage: :engineer})
      elsewhere = task_for.("My work elsewhere", %{project: other_project, stage: :engineer})

      runs =
        for task <- [theirs, elsewhere] do
          {:ok, run} =
            Pipeline.create_run(%{
              task_id: task.id,
              role_id: roles[:engineer].id,
              status: :running,
              started_at: DateTime.utc_now()
            })

          run
        end

      assert {:ok, view, _html} = live(init_test_session(conn, %{selected_project_id: project.id}), ~p"/")

      assert has_element?(view, "#in-progress-task-#{mine.id}")
      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "0")
      assert has_element?(view, "#stat-in-progress [data-qa='stat-value']", "1")

      for run <- runs do
        {:ok, _finished} =
          Pipeline.update_run(run, %{status: :finished, stage_outcome: :done, completed_at: DateTime.utc_now()})

        Phoenix.PubSub.broadcast(Rail.PubSub, "pipeline", {:pipeline_changed, run.task_id})
      end

      assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "0")
      assert has_element?(view, "#stat-in-progress [data-qa='stat-value']", "1")
      assert has_element?(view, "#in-progress-count", ~r/^\s*1 task\s*$/)

      for task <- [theirs, elsewhere] do
        refute has_element?(view, "#in-progress-task-#{task.id}")
        refute has_element?(view, "[id^='up-next-'][href^='/tasks/#{task.id}']")
      end

      assert has_element?(view, "#overview-view-mine[aria-pressed='true']")
      assert has_element?(view, "#selected-project-name", project.name)
    end

    test "a refresh keeps the project switcher open and the view the user picked", %{
      conn: conn,
      task_for: task_for
    } do
      task = task_for.("Changes underneath", %{})

      assert {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#project-switcher-button") |> render_click()
      assert has_element?(view, "#project-switcher-dialog")

      Phoenix.PubSub.broadcast(Rail.PubSub, "pipeline", {:pipeline_changed, task.id})

      assert has_element?(view, "#project-switcher-dialog")
      refute_redirected(view)
      refute_patched(view)

      view |> element("#overview-view-everyone") |> render_click()
      assert_patched(view, ~p"/?everyone=true")

      Phoenix.PubSub.broadcast(Rail.PubSub, "pipeline", {:pipeline_changed, task.id})

      assert has_element?(view, "#overview-view-everyone[aria-pressed='true']")
      refute_redirected(view)
      refute_patched(view)
    end
  end
end

defmodule RailWeb.OverviewLiveDispatchTest do
  # Serial: switching dispatch off is global, and would refuse async tests' spawns.
  use RailWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rail.Users

  test "the dispatch banner shows while dispatch is switched off", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_dispatch",
        login: "overview_dispatch_user",
        email: "overview_dispatch_user@example.com",
        admin: true
      })

    previous = Application.get_env(:rail, :no_dispatch)
    Application.put_env(:rail, :no_dispatch, true)
    on_exit(fn -> Application.put_env(:rail, :no_dispatch, previous) end)

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/")
    assert render(view) =~ "RAIL_NO_DISPATCH=1 is set"
  end
end

defmodule RailWeb.OverviewLiveIssueEventsTest do
  # Serial: the page reloads on any task's pipeline event, which async tests send all the time, and
  # one landing here would reload it for a reason of its own. What is checked is that issue events
  # alone leave it as it was.
  use RailWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Users

  test "a new issue or a comment on one moves no task, so the page is left as it was", %{
    conn: conn,
    project: project
  } do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_overview_issue_events",
        login: "overview_issue_events_user",
        email: "overview_issue_events_user@example.com",
        admin: true
      })

    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_issue_events", "identifier" => "QUE-1", "title" => "Queued work"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Queued work"})
    issue = issue |> Issue.tracker_changeset(%{owner_user_id: user.id}) |> Repo.update!()
    {:ok, task} = Pipeline.create_task(issue, :engineer)

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/")

    assert has_element?(view, "#in-progress-task-#{task.id}[data-state='queued']")

    {:ok, _run} =
      Pipeline.create_run(%{task_id: task.id, role_id: engineer.id, status: :running, started_at: DateTime.utc_now()})

    Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_created, issue.id})
    Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_comments_changed, issue.id})

    assert has_element?(view, "#in-progress-task-#{task.id}[data-state='queued']")
  end
end
