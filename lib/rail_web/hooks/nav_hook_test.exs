defmodule RailWeb.Hooks.NavHookTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Tools.Schemas.Backend
  alias Rail.Triage
  alias Rail.Users

  setup %{conn: conn, project: project} do
    {:ok, other_project} =
      Projects.create_project(system_scope(), %{
        name: "Nav Hook Other Project",
        github_repo: "org/nav-hook-other",
        github_installation_id: 13_120,
        key: "OTH",
        default_branch: "main",
        clone_path: "/tmp/repos/nav-hook-other",
        linear_state_ids: %{"triage" => "st_triage"},
        active: true
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_nav_hook_selection",
        login: "nav_hook_selection_user",
        email: "nav_hook_selection_user@example.com",
        admin: false
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id, other_project.id]})

    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_nav_hook_1",
        identifier: "TST-1",
        title: "Issue in the selected project",
        state: :triage
      })
      |> Repo.insert!()

    other_issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: other_project.id,
        external_id: "lin_nav_hook_2",
        identifier: "OTH-1",
        title: "Issue in the other project",
        state: :triage
      })
      |> Repo.insert!()
      |> Repo.preload(:project)

    {:ok, other_task} = Pipeline.create_task(other_issue, :plan)

    %{
      conn: log_in_user(conn, user),
      user: user,
      other_project: other_project,
      issue: issue,
      other_issue: other_issue,
      other_task: other_task
    }
  end

  test "handles switcher, theme, and rail toggle events", %{conn: conn, project: project} do
    assert {:ok, view, _html} = live(conn, ~p"/issues")

    render_click(view, "toggle_rail", %{})
    render_click(view, "theme_changed", %{"theme" => "light"})
    render_click(view, "toggle_project_switcher", %{})
    assert has_element?(view, "#project-switcher-dialog")

    render_click(view, "close_project_switcher", %{})
    refute has_element?(view, "#project-switcher-dialog")

    render_click(view, "select_project", %{"project_id" => project.id})
    assert_redirect(view, ~p"/project-selection?#{[project_id: project.id, return_to: "/issues"]}")

    assert {:ok, view, _html} = live(conn, ~p"/issues")
    render_click(view, "select_project", %{"project_id" => ""})
    assert_redirect(view, ~p"/project-selection?#{[project_id: "", return_to: "/issues"]}")
  end

  test "opening an issue from another project keeps All projects", %{
    conn: conn,
    issue: issue,
    other_issue: other_issue
  } do
    assert {:ok, view, _html} = live(conn, ~p"/issues/#{other_issue.identifier}")
    assert has_element?(view, "#selected-project-name", "All projects")

    assert {:ok, issues, _html} = view |> element("#nav-issues") |> render_click() |> follow_redirect(conn)
    assert has_element?(issues, "#issue-card-#{issue.id}")
    assert has_element?(issues, "#issue-card-#{other_issue.id}")
  end

  test "opening a task from another project keeps the selected project", %{
    conn: conn,
    project: project,
    issue: issue,
    other_issue: other_issue,
    other_task: other_task
  } do
    conn = init_test_session(conn, %{selected_project_id: project.id})

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{other_task.id}")
    assert has_element?(view, "#selected-project-name", project.name)

    assert {:ok, overview, _html} = view |> element("#nav-overview") |> render_click() |> follow_redirect(conn)
    assert has_element?(overview, "#selected-project-name", project.name)

    assert {:ok, issues, _html} = overview |> element("#nav-issues") |> render_click() |> follow_redirect(conn)
    assert has_element?(issues, "#issues-subtitle", project.name)
    assert has_element?(issues, "#issue-card-#{issue.id}")
    refute has_element?(issues, "#issue-card-#{other_issue.id}")
  end

  test "the Issues breadcrumb returns to the list still filtered", %{
    conn: conn,
    project: project,
    issue: issue,
    other_issue: other_issue
  } do
    conn = init_test_session(conn, %{selected_project_id: project.id})

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{other_issue.identifier}")

    assert {:ok, issues, _html} = view |> element("#issue-back-link") |> render_click() |> follow_redirect(conn)
    assert has_element?(issues, "#issues-subtitle", project.name)
    assert has_element?(issues, "#issue-card-#{issue.id}")
    refute has_element?(issues, "#issue-card-#{other_issue.id}")
  end

  test "a page whose URL names no project keeps the selection", %{
    conn: conn,
    project: project,
    other_task: other_task
  } do
    conn = init_test_session(conn, %{selected_project_id: project.id})

    assert {:ok, issues, _html} = live(conn, ~p"/issues")
    assert has_element?(issues, "#selected-project-name", project.name)

    assert {:ok, task, _html} = live(conn, ~p"/tasks/#{other_task.id}")
    assert has_element?(task, "#selected-project-name", project.name)
  end

  test "a project in the URL does not change the selection", %{
    conn: conn,
    project: project,
    other_project: other_project,
    other_issue: other_issue
  } do
    conn = init_test_session(conn, %{selected_project_id: project.id})

    assert {:ok, view, _html} = live(conn, ~p"/issues?project=#{other_project.id}")
    assert has_element?(view, "#selected-project-name", project.name)
    refute has_element?(view, "#issue-card-#{other_issue.id}")
  end

  describe "a user granted only one project" do
    setup %{
      conn: conn,
      user: user,
      project: project,
      issue: issue,
      other_project: other_project,
      other_task: other_task
    } do
      {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})

      {:ok, admin} =
        Users.register_oauth_user(%{
          github_id: "gh_nav_hook_admin",
          login: "nav_hook_admin",
          email: "nav_hook_admin@example.com",
          admin: true
        })

      {:ok, other_role} =
        Roles.create_role(system_scope(), other_project, %{
          stage: :plan,
          name: "Product",
          model: "claude-opus-5-5",
          system_prompt: "You write tickets.",
          cli: :claude
        })

      {:ok, role} = Roles.get_role(project_id: project.id, stage: :plan)
      {:ok, task} = Pipeline.create_task(Repo.preload(issue, :project), :plan)
      now = DateTime.utc_now()

      for {task, role} <- [{task, role}, {other_task, other_role}] do
        {:ok, _done} =
          Pipeline.create_run(%{
            task_id: task.id,
            role_id: role.id,
            status: :finished,
            stage_outcome: :done,
            started_at: DateTime.shift(now, hour: -1),
            completed_at: now
          })
      end

      %{project: triage_project} = triage_project()
      %{workspace: workspace, channel: channel} = connect_slack_channel(triage_project)
      {:ok, thread} = Triage.handle_slack_event(workspace, slack_message_event(channel, %{}))
      triage_with(thread, %{"title" => "Elsewhere", "items" => [triage_bug()]})

      %{conn: log_in_user(conn, user), admin_conn: log_in_user(conn, admin), triage_project: triage_project}
    end

    test "sees only that project in the switcher, and the badges count only its work", %{
      conn: conn,
      project: project,
      other_project: other_project
    } do
      assert {:ok, view, _html} = live(conn, ~p"/issues")

      assert has_element?(view, "#active-project-count", "1")
      view |> element("#project-switcher-button") |> render_click()
      assert has_element?(view, "#project-option-#{project.id}")
      refute has_element?(view, "#project-option-#{other_project.id}")

      assert has_element?(view, "#attention-badge", "1")
      refute has_element?(view, "#triage-badge")
    end

    test "an admin sees every project, and the badges count all of them", %{
      admin_conn: admin_conn,
      project: project,
      other_project: other_project,
      triage_project: triage_project
    } do
      assert {:ok, view, _html} = live(admin_conn, ~p"/issues")

      view |> element("#project-switcher-button") |> render_click()

      for %{id: id} <- [project, other_project, triage_project] do
        assert has_element?(view, "#project-option-#{id}")
      end

      assert has_element?(view, "#attention-badge", "2")
      assert has_element?(view, "#triage-badge", "1")
    end

    test "a selected project they lost access to is neither listed nor selected on the next page", %{
      conn: conn,
      issue: issue,
      other_project: other_project,
      other_issue: other_issue
    } do
      conn = init_test_session(conn, %{selected_project_id: other_project.id})

      assert {:ok, view, _html} = live(conn, ~p"/issues")
      assert has_element?(view, "#selected-project-name", "All projects")
      assert has_element?(view, "#issue-card-#{issue.id}")
      refute has_element?(view, "#issue-card-#{other_issue.id}")

      view |> element("#project-switcher-button") |> render_click()
      refute has_element?(view, "#project-option-#{other_project.id}")
    end
  end

  test "every page says so when a backend was signed out with nobody signing it out", %{conn: conn} do
    backend =
      Repo.insert!(
        Backend.changeset(%Backend{}, %{
          name: :claude,
          executable_path: "/bin/sleep",
          label: "work"
        })
      )

    assert {:ok, view, _html} = live(conn, ~p"/issues")
    refute has_element?(view, "[data-qa=lost_backend_banner]")

    Repo.update!(Backend.usage_changeset(backend, %{status: :signed_out, session_lost_at: DateTime.utc_now()}))

    assert {:ok, view, _html} = live(conn, ~p"/issues")
    assert has_element?(view, "#lost-backend-banner-#{backend.id}", "The work backend lost its sign-in")
    assert has_element?(view, "#lost-backend-banner-#{backend.id} a[href='/settings/backends']")
  end
end
