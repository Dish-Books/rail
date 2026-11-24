defmodule RailWeb.IssueLiveTest do
  use RailWeb.ConnCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Clients.R2
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.LinkTrackerUrl
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users
  alias Rail.Workflows.Schemas.Workflow
  alias Rail.Workflows.Schemas.WorkflowDefinition

  setup {Req.Test, :verify_on_exit!}

  setup %{conn: conn, project: project} do
    # A role's prompt is read from the project's clone, which another test may have made, so reading it here
    # would spawn git: these see no prompt file on the default branch, as when there is no clone. A deleted task
    # takes its worktree and branch in that clone with it.
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)
    stub(Git, :remove_worktree, fn _clone_path, _worktree_path -> :ok end)
    stub(Git, :delete_branch, fn _clone_path, _branch -> :ok end)

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issue_live",
        login: "issue_live_user",
        name: "Issue Live",
        email: "issue_live_user@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})

    # An issue with no task looks for a pull request to start at Review on, which no test here has unless it says.
    stub(Issues, :link_pull_request, fn _scope, _issue -> {:ok, nil} end)
    # Blockers are read only when a test here asks.
    stub(Issues, :get_blockers, fn _issues -> %{} end)

    %{conn: log_in_user(conn, user), user: user, project: project}
  end

  test "a support person without GitHub is sent to Support, not shown the issue read-only", %{conn: conn} do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "issue_live_role_#{id}",
        login: "issue_live-role-#{id}",
        email: "issue_live_role_#{id}@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{role: :support})
    {:ok, user} = Users.unlink_github(Scope.for_user(user))

    assert {:error, {:redirect, %{to: "/support"}}} = live(log_in_user(conn, user), ~p"/issues/RAIL-41")
  end

  test "shows the issue's title, description and properties", %{conn: conn, user: user, project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        owner_user_id: user.id,
        identifier: "IPG-7",
        title: "AP Aging exports to PDF",
        description: "The report offers **one** export.",
        priority: :high,
        estimate: 2,
        state: :in_progress,
        branch_name: "ipg-7-ap-aging"
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    assert has_element?(view, "#issue-identifier", "IPG-7")
    assert has_element?(view, "#issue-title-#{issue.id}", "AP Aging exports to PDF")
    assert has_element?(view, "#issue-description-#{issue.id} strong", "one")
    assert has_element?(view, "#issue-status", "In Progress")
    assert has_element?(view, "#issue-priority", "High")
    assert has_element?(view, "#issue-owner", "Issue Live")
    assert has_element?(view, "#issue-estimate", "2 Points")
    assert has_element?(view, "#issue-project", "Test Project")
    assert has_element?(view, "#issue-branch[phx-hook='CopyText'][data-copy-text='ipg-7-ap-aging']")
    assert has_element?(view, "#issue-cycle", "No cycle")
  end

  test "an issue a workflow opened names it under the title, linked to Settings for someone who is not an admin", %{
    conn: conn,
    project: project
  } do
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

    # The byline reads when the issue was opened.
    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 08:00:00.000000Z] end)

    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        workflow_id: workflow.id,
        identifier: "WFP-1",
        title: "Flaky test sweep 2026-10-12",
        state: :todo
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    assert has_element?(view, "#issue-workflow-byline", "Opened by the Flaky test sweep workflow on Oct 12, 08:00 UTC")

    assert has_element?(
             view,
             ~s(#issue-workflow-byline a#issue-workflow-link[href="/settings/workflows"]),
             "Flaky test sweep"
           )

    assert has_element?(view, "#issue-owner", "Unassigned")

    # Only a workflow change on this issue's project reloads it.
    Phoenix.PubSub.broadcast(Rail.PubSub, "workflows", {:workflows_changed, "prj_elsewhere"})

    workflow
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_embed(:definition, %{name: "Flake sweep"})
    |> Repo.update!()

    Phoenix.PubSub.broadcast(Rail.PubSub, "workflows", {:workflows_changed, project.id})
    assert has_element?(view, "#issue-workflow-byline", "Opened by the Flake sweep workflow")
  end

  test "an admin follows the workflow's name to Settings, and a filed issue has no byline", %{
    conn: conn,
    project: project
  } do
    {:ok, admin} =
      Users.register_oauth_user(%{
        github_id: "gh_issue_live_admin",
        login: "issue_admin",
        email: "issue_admin@example.com"
      })

    {:ok, _admin} = Users.update_user(system_scope(), admin, %{admin: true})

    workflow =
      Repo.insert!(%Workflow{
        project_id: project.id,
        path: ".rail/workflows/sweep.yml",
        definition: %WorkflowDefinition{name: "Sweep", schedule: "0 9 * * 1", instructions: "Sweep the flaky tests."},
        next_run_at: ~U[2026-10-12 09:00:00Z]
      })

    [opened, filed] =
      for {workflow_id, n} <- [{workflow.id, 1}, {nil, 2}] do
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: project.id,
          workflow_id: workflow_id,
          identifier: "WFA-#{n}",
          title: "Admin #{n}",
          state: :todo
        })
        |> Repo.insert!()
      end

    admin_conn = log_in_user(conn, Repo.reload!(admin))

    assert {:ok, view, _html} = live(admin_conn, ~p"/issues/#{opened.identifier}")
    assert has_element?(view, ~s(#issue-workflow-link[href="/settings/workflows"]), "Sweep")

    assert {:ok, view, _html} = live(admin_conn, ~p"/issues/#{filed.identifier}")
    refute has_element?(view, "#issue-workflow-byline")
  end

  test "the assignee can be changed to anyone who can open the issue, or cleared", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, %{id: teammate_id} = teammate} =
      Users.register_oauth_user(%{
        github_id: "gh_issue_teammate",
        login: "teammate",
        name: "Paulo Teammate",
        email: "teammate@example.com"
      })

    teammate |> Ecto.Changeset.change(project_ids: [project.id]) |> Repo.update!()

    # Only people who can open the issue are offered: admins and those granted its project.
    person = fn login, attrs ->
      {:ok, other} =
        Users.register_oauth_user(%{
          github_id: "gh_#{login}_issue-live",
          login: "#{login}-issue-live",
          name: login,
          email: "#{login}-issue-live@example.com"
        })

      other |> Ecto.Changeset.change(attrs) |> Repo.update!()
    end

    elsewhere = person.("elsewhere", %{project_ids: ["prj_other"]})
    admin = person.("admin", %{admin: true})

    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-9",
        title: "Assign me",
        state: :todo
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    assert has_element?(view, "#issue-estimate", "No points")

    assert has_element?(view, "#issue-assign-#{user.id}")
    refute has_element?(view, "#issue-assign-#{elsewhere.id}")
    assert has_element?(view, "#issue-assign-#{admin.id}")

    view |> element("#issue-owner-search-form") |> render_change(%{"q" => "nobody"})
    refute has_element?(view, "#issue-assign-#{teammate.id}")

    view |> element("#issue-owner-search-form") |> render_change(%{"q" => "paulo"})
    view |> element("#issue-assign-#{teammate.id}") |> render_click()

    assert has_element?(view, "#issue-owner", "Paulo Teammate")
    assert %Issue{owner_user_id: ^teammate_id} = Repo.get!(Issue, issue.id)
    assert_enqueued(worker: SyncIssue, args: %{issue_id: issue.id})

    view |> element("#issue-assign-none") |> render_click()

    assert has_element?(view, "#issue-owner", "Unassigned")
    assert %Issue{owner_user_id: nil} = Repo.get!(Issue, issue.id)
  end

  test "an issue offers no link to itself, and an owner picked on it shows in every open tab", %{
    conn: conn,
    user: %{id: user_id},
    project: project
  } do
    {:ok, %Issue{id: issue_id, branch_name: branch_name}} =
      Issues.create_issue(system_scope(), project, %{title: "Kept here"})

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
    assert {:ok, second, _html} = live(conn, ~p"/issues/#{issue_id}")

    refute has_element?(view, "#issue-tracker-link")
    assert has_element?(view, "#issue-branch[data-copy-text='#{branch_name}']")

    view |> element("#issue-assign-#{user_id}") |> render_click()
    assert has_element?(view, "#issue-owner", "Issue Live")

    assert :ok = perform_job(SyncIssue, %{issue_id: issue_id})

    assert has_element?(second, "#issue-owner", "Issue Live")
  end

  test "the task link reads the latest run at the task's stage, not one it retried", %{
    conn: conn,
    project: project
  } do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-12",
        title: "Retry after failure",
        state: :todo
      })
      |> Repo.insert!()
      |> Repo.preload(:project)

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

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    assert has_element?(view, "#issue-task-link", "Review running")
  end

  test "the task link of a Review round waiting on a person reads Review", %{conn: conn, project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-13",
        title: "Findings to rule",
        state: :todo
      })
      |> Repo.insert!()
      |> Repo.preload(:project)

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

    {:ok, _pass} = Pipeline.save_review(Repo.preload(task, :issue))

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    assert has_element?(view, "#issue-task-link", ~r/^\s*Review\s*$/)
  end

  test "the task link of a plan sent to the tech leads reads Ready for tech lead", %{conn: conn, project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-14",
        title: "Plan with the leads",
        state: :in_progress
      })
      |> Repo.insert!()
      |> Repo.preload(:project)

    {:ok, task} = Pipeline.create_task(issue, :plan)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    {:ok, plan} = Roles.get_role(project_id: project.id, stage: :plan)

    {:ok, _done} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: plan.id,
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.utc_now()
      })

    Repo.insert!(%Round{task_id: task.id, number: 1, plan: "A plan.", ready_at: DateTime.utc_now()})

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    assert has_element?(view, "#issue-task-link", "Ready for tech lead")
  end

  test "an issue with no task can be started from its page, which stays put and shows the task", %{
    conn: conn,
    project: project
  } do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-8",
        title: "Start me",
        state: :todo
      })
      |> Repo.insert!()

    expect(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)

    expect(Tools, :start_os_process, fn %Run{} = run, _argv ->
      {:ok, %OsProcess{task_id: run.task_id, run: run}}
    end)

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")
    allow(Git, self(), view.pid)
    allow(Tools, self(), view.pid)

    assert has_element?(view, "#issue-description-#{issue.id}", "Add description...")
    assert has_element?(view, "#issue-owner", "Unassigned")
    refute has_element?(view, "#issue-task-link")

    render_async(view)
    assert has_element?(view, "#issue-start-plan[phx-hook=StartFocus][data-chip=issue-task-link]")
    view |> element("#issue-start-plan") |> render_click()

    assert %Task{id: task_id, stage: :plan} = Repo.get_by(Task, issue_id: issue.id)
    refute_redirected(view)
    assert has_element?(view, "#issue-task-link[href='/tasks/#{task_id}']", "Plan")
    refute has_element?(view, "#issue-start")
  end

  test "after Start, the issue page's Task section follows the run with no reload", %{conn: conn, project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-31",
        title: "Follow me",
        state: :todo
      })
      |> Repo.insert!()

    expect(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    expect(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")
    allow(Git, self(), view.pid)
    allow(Tools, self(), view.pid)
    render_async(view)
    view |> element("#issue-start-plan") |> render_click()

    assert %Task{id: task_id} = Repo.get_by(Task, issue_id: issue.id)
    assert has_element?(view, "#issue-task-link", "Plan running")

    send(view.pid, {:pipeline_changed, "tsk_elsewhere"})
    assert has_element?(view, "#issue-task-link", "Plan running")

    # The real writer, which says so on "pipeline".
    assert {:ok, %Run{status: :waiting_for_resources}} =
             Run |> Repo.get_by!(task_id: task_id) |> Pipeline.update_run(%{status: :waiting_for_resources})

    assert has_element?(view, "#issue-task-link", "Plan waiting for resources")
  end

  test "Start on an issue closed since the page opened starts nothing and the page shows it closed", %{
    conn: conn,
    project: project
  } do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-32",
        title: "Closed meanwhile",
        state: :todo
      })
      |> Repo.insert!()

    reject(&Git.get_or_create_worktree/2)

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")
    render_async(view)
    assert has_element?(view, "#issue-start-plan")

    # Closed elsewhere with no word to this page yet.
    issue |> Issue.tracker_changeset(%{state: :done}) |> Repo.update!()
    view |> element("#issue-start-plan") |> render_click()

    refute Repo.get_by(Task, issue_id: issue.id)
    refute_redirected(view)
    refute has_element?(view, "#issue-start")
    refute has_element?(view, "#flash-error")
  end

  test "an in-progress issue with no task can still be started at Plan from its page", %{
    conn: conn,
    project: project
  } do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-41",
        title: "Moving outside Rail",
        state: :in_progress
      })
      |> Repo.insert!()

    expect(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)

    expect(Tools, :start_os_process, fn %Run{} = run, _argv ->
      {:ok, %OsProcess{task_id: run.task_id, run: run}}
    end)

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")
    allow(Git, self(), view.pid)
    allow(Tools, self(), view.pid)

    render_async(view)
    view |> element("#issue-start-plan") |> render_click()

    assert %Task{id: task_id, stage: :plan} = Repo.get_by(Task, issue_id: issue.id)
    refute_redirected(view)
    assert has_element?(view, "#issue-task-link[href='/tasks/#{task_id}']", "Plan")
    refute has_element?(view, "#issue-start")
  end

  test "a second page on an issue shows the new owner and drops Start when someone starts it", %{
    conn: conn,
    project: project
  } do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-20",
        title: "Open in two tabs",
        state: :todo
      })
      |> Repo.insert!()

    expect(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    expect(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)

    assert {:ok, starting, _html} = live(conn, ~p"/issues/#{issue.identifier}")
    assert {:ok, second, _html} = live(conn, ~p"/issues/#{issue.identifier}")
    allow(Git, self(), starting.pid)
    allow(Tools, self(), starting.pid)

    render_async(starting)
    render_async(second)
    assert has_element?(second, "#issue-owner", "Unassigned")
    assert has_element?(second, "#issue-start-plan")

    starting |> element("#issue-start-plan") |> render_click()

    assert has_element?(second, "#issue-owner", "Issue Live")
    refute has_element?(second, "#issue-start-plan")
    assert has_element?(second, "#issue-task-link")
  end

  test "a second page on an issue that starts at Engineer reads the run, not Queued", %{conn: conn, project: project} do
    issue =
      %Issue{skipped_steps: [:product, :design, :architect]}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-21",
        title: "Open in two tabs at Engineer",
        state: :todo
      })
      |> Repo.insert!()

    stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    stub(Git, :branch_fingerprint, fn _worktree_path -> nil end)
    expect(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)

    assert {:ok, starting, _html} = live(conn, ~p"/issues/#{issue.identifier}")
    assert {:ok, second, _html} = live(conn, ~p"/issues/#{issue.identifier}")
    allow(Git, self(), starting.pid)
    allow(Tools, self(), starting.pid)

    render_async(starting)
    render_async(second)
    starting |> element("#issue-start-plan") |> render_click()

    assert has_element?(second, "#issue-task-link", "Implement running")
  end

  test "a stale page whose issue has since started shows the task, and starts nothing", %{
    conn: conn,
    project: project
  } do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-40",
        title: "Started elsewhere",
        state: :todo
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")
    render_async(view)

    {:ok, task} = issue |> Repo.preload(:project) |> Pipeline.create_task(:plan)
    reject(&Pipeline.start_task/2)
    allow(Pipeline, self(), view.pid)

    # Sent as the stale tab sends it: the project is shared, so another test's sync or workflow change can reload this
    # page onto the new task, and drop its Start button, before a click on the button could land.
    render_click(view, "start_task", %{})

    refute_redirected(view)
    assert has_element?(view, "#issue-task-link[href='/tasks/#{task.id}']")
    refute has_element?(view, "#issue-start")
    refute has_element?(view, "#flash-error")
  end

  test "an issue offers one Start at Plan button, where every task begins", %{conn: conn, project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-17",
        title: "Already written",
        state: :todo
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    assert has_element?(view, "#issue-start-plan", "Plan")
    refute has_element?(view, "#issue-start-product")
    refute has_element?(view, "#issue-start-design")
    refute has_element?(view, "#issue-start-architect")
  end

  test "a Tested ticket's page reads Tested and still offers its status, owner and comment controls", %{
    conn: conn,
    project: project
  } do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-40",
        title: "Tested already",
        state: :in_review
      })
      |> Repo.insert!()
      |> Issue.tracker_changeset(%{state: :done})
      |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")
    assert has_element?(view, "#issue-testing-link[href='/testing/#{issue.id}'] [data-testing-state='waiting']")

    {:ok, _tested} = Issues.mark_issue_tested(system_scope(), issue)

    assert has_element?(view, "#issue-testing [data-testing-state='tested']", "Tested")
    refute has_element?(view, "#issue-testing-link")
    assert has_element?(view, "#issue-status-picker-#{issue.id}")
    assert has_element?(view, "#issue-owner-menu")
    assert has_element?(view, "#issue-comment-form")
  end

  test "a ticket not in Done shows no testing line, though it starts Waiting", %{conn: conn, project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-42",
        title: "Still in review",
        state: :in_review
      })
      |> Repo.insert!()

    assert %Issue{testing_state: :waiting} = Repo.reload!(issue)

    {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")
    assert has_element?(view, "#issue-title-#{issue.id}", "Still in review")
    refute has_element?(view, "#issue-testing")
  end

  test "an issue whose work has a pull request links it, and offers Review in place of Plan", %{
    conn: conn,
    project: project
  } do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-30",
        title: "Built by hand",
        state: :in_progress
      })
      |> Repo.insert!()

    expect(Issues, :link_pull_request, fn _scope, %Issue{id: issue_id} = found when issue_id == issue.id ->
      attrs = %{pr_number: 41, pr_url: "https://github.com/org/app/pull/41", pr_title: "Vendor filter"}
      found |> Issue.pull_request_changeset(attrs) |> Repo.update!()
      {:ok, %{"number" => 41}}
    end)

    expect(Pipeline, :adopt_pull_request, fn _scope, %Issue{id: issue_id} = adopted when issue_id == issue.id ->
      Pipeline.create_task(Repo.preload(adopted, :project), :review)
    end)

    assert {:ok, view, html} = live(conn, ~p"/issues/#{issue.identifier}")
    allow(Pipeline, self(), view.pid)
    assert html =~ "Looking for a pull request"

    render_async(view)

    refute has_element?(view, "#issue-start-checking")
    refute has_element?(view, "#issue-start-plan")
    assert has_element?(view, "#issue-pull-request[href='https://github.com/org/app/pull/41']", "#41")
    assert has_element?(view, "#issue-pull-request", "Vendor filter")

    assert has_element?(view, "#issue-start-review[phx-hook=StartFocus][data-chip=issue-task-link]")
    view |> element("#issue-start-review") |> render_click()

    assert %Task{id: task_id, stage: :review} = Repo.get_by(Task, issue_id: issue.id)
    refute_redirected(view)
    assert has_element?(view, "#issue-task-link[href='/tasks/#{task_id}']")
    refute has_element?(view, "#issue-start-review")
  end

  test "an issue with a linked pull request offers Review without asking GitHub again", %{
    conn: conn,
    project: project
  } do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-33",
        title: "Linked already",
        state: :in_progress
      })
      |> Repo.insert!()
      |> Issue.pull_request_changeset(%{pr_number: 42, pr_url: "https://github.com/org/app/pull/42", pr_title: "Linked"})
      |> Repo.update!()

    reject(Issues, :link_pull_request, 2)

    assert {:ok, view, html} = live(conn, ~p"/issues/#{issue.identifier}")
    refute html =~ "Looking for a pull request"

    assert has_element?(view, "#issue-start-review")
    refute has_element?(view, "#issue-start-review[phx-disable-with]")
    assert has_element?(view, "#issue-pull-request", "Linked")
    refute has_element?(view, "#issue-start-plan")
  end

  test "an issue offers Plan when GitHub has no pull request for it or cannot say", %{conn: conn, project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-32",
        title: "Not started",
        state: :todo
      })
      |> Repo.insert!()

    for found <- [{:ok, nil}, {:error, :github_down}] do
      expect(Issues, :link_pull_request, fn _scope, _issue -> found end)

      assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")
      render_async(view)

      assert has_element?(view, "#issue-start-plan")
      refute has_element?(view, "#issue-start-review")
      refute has_element?(view, "#issue-pull-request")
    end
  end

  test "a pull request that cannot be reviewed says why", %{conn: conn, project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-31",
        title: "Built elsewhere",
        state: :in_progress
      })
      |> Repo.insert!()
      |> Issue.pull_request_changeset(%{pr_number: 41, pr_url: "https://github.com/org/app/pull/41"})
      |> Repo.update!()

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")
    allow(Pipeline, self(), view.pid)

    for {reason, said} <- [
          {:pull_request_from_fork, "That pull request comes from a fork, which Rail cannot push fixes to."},
          {{:pull_request_base, "release"}, "That pull request merges into release, not the default branch."},
          {:pull_request_taken, "Another task already works on that pull request's branch."},
          {"no checkout", "Could not check out the pull request: no checkout"},
          {:task_exists, "Could not start: :task_exists"}
        ] do
      expect(Pipeline, :adopt_pull_request, fn _scope, _issue -> {:error, reason} end)

      view |> element("#issue-start-review") |> render_click()

      assert has_element?(view, "#flash-error", said)
    end

    # Starting found it closed, which let the link go, so the page offers Plan again.
    expect(Pipeline, :adopt_pull_request, fn _scope, adopted ->
      adopted |> Issue.pull_request_changeset(%{pr_number: nil, pr_url: nil}) |> Repo.update!()
      {:error, :no_pull_request}
    end)

    view |> element("#issue-start-review") |> render_click()

    assert has_element?(view, "#flash-error", "The pull request is no longer open.")
    assert has_element?(view, "#issue-start-plan")
  end

  test "a Canceled issue reads as Canceled and offers no start", %{conn: conn, project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-20",
        title: "Same as IPG-7",
        state: :canceled
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    assert has_element?(view, "#issue-status", "Canceled")
    refute has_element?(view, "#issue-start")
  end

  test "a status picked in Properties shows at once, in a second tab too, and is saved", %{
    conn: conn,
    project: project
  } do
    %Issue{id: issue_id} =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-30",
        title: "Pick a status",
        state: :in_progress
      })
      |> Repo.insert!()

    stub(Issues, :get_statuses, fn _scope, _project ->
      {:ok, [%{id: "st_review", name: "In Review", state: :in_review}]}
    end)

    {:ok, view, _html} = live(conn, ~p"/issues/IPG-30")
    {:ok, other_view, _html} = live(conn, ~p"/issues/IPG-30")

    view |> element("#issue-status") |> render_click()
    render_async(view)

    view |> element("#issue-status-picker-#{issue_id}-status-st_review") |> render_click()

    assert has_element?(view, "#issue-status", "In Review")
    assert has_element?(other_view, "#issue-status", "In Review")
    assert %Issue{state: :in_review} = Repo.get!(Issue, issue_id)
    refute_enqueued(worker: SyncIssue)
  end

  test "an open page follows its issue closing elsewhere and stops offering to start it", %{
    conn: conn,
    project: project
  } do
    [open, other] =
      for identifier <- ["IPG-21", "IPG-22"] do
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: project.id,
          identifier: identifier,
          title: "Open #{identifier}",
          state: :todo
        })
        |> Repo.insert!()
      end

    assert {:ok, view, _html} = live(conn, ~p"/issues/IPG-21")
    assert has_element?(view, "#issue-start")

    canceled = %{id: "canceled", name: "Canceled", state: :canceled}

    # An unrelated issue closing leaves this page as it was.
    assert {:ok, _other} = Issues.set_issue_status(system_scope(), other, canceled)
    assert has_element?(view, "#issue-status", "Todo")
    assert has_element?(view, "#issue-start")

    assert {:ok, _issue} = Issues.set_issue_status(system_scope(), open, canceled)
    assert has_element?(view, "#issue-status", "Canceled")
    refute has_element?(view, "#issue-start")
  end

  test "an issue that cannot be started says why and keeps no task", %{conn: conn, project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-11",
        title: "No checkout",
        state: :todo
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    expect(Git, :get_or_create_worktree, fn _project, _task -> {:error, "no checkout"} end)
    allow(Git, self(), view.pid)

    render_async(view)
    view |> element("#issue-start-plan") |> render_click()

    assert has_element?(view, "#flash-error", "Could not create the worktree: no checkout")
    assert has_element?(view, "#issue-start-plan")
    refute has_element?(view, "#issue-task-link")
    refute Repo.get_by(Task, issue_id: issue.id)
  end

  test "shows comment threads with their replies, and refreshes when a comment arrives", %{
    conn: conn,
    project: project
  } do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-10",
        title: "Discussed",
        state: :todo
      })
      |> Repo.insert!()

    %Comment{id: thread_id} =
      %Comment{}
      |> Comment.changeset(%{
        issue_id: issue.id,
        body: "Should all four wait on **DIS-1377**?",
        author_name: "paulo",
        inserted_at: DateTime.shift(DateTime.utc_now(), day: -4)
      })
      |> Repo.insert!()

    %Comment{id: reply_id} =
      %Comment{}
      |> Comment.changeset(%{issue_id: issue.id, parent_id: thread_id, body: "yes"})
      |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    assert has_element?(view, "#comment-#{thread_id}", "paulo")
    assert has_element?(view, "#comment-#{thread_id}", "4d ago")
    assert has_element?(view, "#comment-#{thread_id} strong", "DIS-1377")
    assert has_element?(view, "#comment-#{thread_id} #comment-#{reply_id}", "yes")
    assert has_element?(view, "#comment-reply-form-#{thread_id} input[name='parent_id'][value='#{thread_id}']")

    %Comment{id: late_id} =
      %Comment{}
      |> Comment.changeset(%{issue_id: issue.id, body: "Arrived from elsewhere"})
      |> Repo.insert!()

    send(view.pid, {:issue_comments_changed, issue.id})

    assert has_element?(view, "#comment-#{late_id}", "Arrived from elsewhere")
  end

  test "posting a comment and a reply saves them and shows them", %{conn: conn, project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "ICP-1",
        title: "Talk about me",
        state: :todo
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    view |> element("#issue-comment-form") |> render_submit(%{"body" => "  First thought  "})

    %Comment{id: thread_id, parent_id: nil} = Repo.get_by!(Comment, issue_id: issue.id, body: "First thought")
    assert has_element?(view, "#comment-#{thread_id}", "First thought")

    view
    |> element("#comment-reply-form-#{thread_id}")
    |> render_submit(%{"body" => "A reply", "parent_id" => thread_id})

    assert %Comment{parent_id: ^thread_id} = Repo.get_by!(Comment, issue_id: issue.id, body: "A reply")
    assert has_element?(view, "#comment-#{thread_id} [id^='comment-com']", "A reply")

    # A blank comment saves nothing.
    view |> element("#issue-comment-form") |> render_submit(%{"body" => "   "})
    assert [_thread, _reply] = Repo.all(from(c in Comment, where: c.issue_id == ^issue.id))
  end

  test "a file put into a reply box goes up through that box, and its refusal shows under it alone", %{
    conn: conn,
    project: project
  } do
    %Issue{id: issue_id} =
      issue =
      %Issue{}
      |> Issue.tracker_changeset(%{project_id: project.id, identifier: "IUP-1", title: "Show me", state: :todo})
      |> Repo.insert!()

    %Comment{id: thread_id} =
      %Comment{} |> Comment.changeset(%{issue_id: issue_id, body: "Where does it land?"}) |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")
    reply_upload = "comment-reply-form-#{thread_id}-upload"

    assert has_element?(
             view,
             "#comment-reply-form-#{thread_id}[data-file-drop] textarea[phx-hook='MarkdownPaste'][data-upload-form='#{reply_upload}']"
           )

    Req.Test.expect(R2, fn r2 -> Plug.Conn.send_resp(r2, 200, "") end)

    view
    |> file_input("##{reply_upload}", :file, [%{name: "after ruling.png", content: "PNG_BYTES", type: "image/png"}])
    |> render_upload("after ruling.png")

    render_async(view)
    assert_push_event(view, "upload_started", %{form: ^reply_upload, ref: ref, name: "after ruling.png"})
    assert_push_event(view, "insert_file", %{form: ^reply_upload, ref: ^ref, url: url, image: true})
    assert url =~ "/issues/#{issue_id}/assets/"

    view
    |> file_input("##{reply_upload}", :file, [%{name: "build-logs.zip", content: "PK", type: "application/zip"}])
    |> preflight_upload()

    view |> element("##{reply_upload}") |> render_change(%{})

    assert has_element?(view, "##{reply_upload}-error", "build-logs.zip is not a PNG, JPEG, GIF, WebP or PDF file.")
    refute has_element?(view, "#issue-comment-form-upload-error")
    refute has_element?(view, "#issue-description-editor-#{issue_id}-upload-error")
  end

  test "a sent reply clears only its own box, and a sent comment only the comment box", %{
    conn: conn,
    project: project
  } do
    %Issue{id: issue_id} =
      issue =
      %Issue{}
      |> Issue.tracker_changeset(%{project_id: project.id, identifier: "IUP-2", title: "Two boxes", state: :todo})
      |> Repo.insert!()

    %Comment{id: thread_id} =
      %Comment{} |> Comment.changeset(%{issue_id: issue_id, body: "First"}) |> Repo.insert!()

    %Comment{id: other_id} =
      %Comment{} |> Comment.changeset(%{issue_id: issue_id, body: "Second"}) |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    for box <- ["comment-reply-form-#{thread_id}-upload", "issue-comment-form-upload"] do
      view
      |> file_input("##{box}", :file, [%{name: "build-logs.zip", content: "PK", type: "application/zip"}])
      |> preflight_upload()

      view |> element("##{box}") |> render_change(%{})
      assert has_element?(view, "##{box}-error", "build-logs.zip is not a PNG, JPEG, GIF, WebP or PDF file.")
    end

    view
    |> element("#comment-reply-form-#{thread_id}")
    |> render_submit(%{"body" => "A reply", "parent_id" => thread_id})

    assert has_element?(view, "#comment-reply-form-#{thread_id}-body-1")
    assert has_element?(view, "#comment-reply-form-#{other_id}-body-0")
    assert has_element?(view, "#issue-comment-form-body-0")
    refute has_element?(view, "#comment-reply-form-#{thread_id}-upload-error")
    assert has_element?(view, "#issue-comment-form-upload-error", "build-logs.zip")

    view |> element("#issue-comment-form") |> render_submit(%{"body" => "A comment"})

    assert has_element?(view, "#issue-comment-form-body-1")
    assert has_element?(view, "#comment-reply-form-#{thread_id}-body-1")
    assert has_element?(view, "#comment-reply-form-#{other_id}-body-0")
  end

  test "a comment with an image shows it, and the same issue open elsewhere shows it without a reload", %{
    conn: conn,
    project: project
  } do
    %Issue{id: issue_id} =
      issue =
      %Issue{}
      |> Issue.tracker_changeset(%{project_id: project.id, identifier: "IUP-3", title: "Pictured", state: :todo})
      |> Repo.insert!()

    url = RailWeb.Endpoint.url() <> "/issues/#{issue_id}/assets/3f2a9c1e-77b0-4c1d-9e1a-8d2f0c6b5a41-shot.png"

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")
    assert {:ok, other, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    view |> element("#issue-comment-form") |> render_submit(%{"body" => "Before and after:\n\n![shot.png](#{url})"})

    assert has_element?(view, "#issue-comments img[src='#{url}'][alt='shot.png']")
    assert has_element?(other, "#issue-comments img[src='#{url}'][alt='shot.png']")

    assert {:ok, reloaded, _html} = live(conn, ~p"/issues/#{issue.identifier}")
    assert has_element?(reloaded, "#issue-comments img[src='#{url}'][alt='shot.png']")
  end

  test "each reason a start fails is said plainly", %{conn: conn, project: project} do
    [issue, dispatch_issue, other_issue] =
      for n <- [12, 13, 16] do
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: project.id,
          identifier: "IPG-#{n}",
          title: "Fails to start",
          state: :todo
        })
        |> Repo.insert!()
      end

    expect(Git, :get_or_create_worktree, fn _project, _task -> {:error, "no checkout"} end)
    expect(Git, :get_or_create_worktree, fn _project, _task -> {:error, {:github_api_error, 503}} end)
    expect(Git, :get_or_create_worktree, 3, fn _project, task -> {:ok, task.worktree_path} end)
    expect(Tools, :start_os_process, fn run, _argv -> {:error, {:spawn_failed, :enoent, run}} end)
    expect(Tools, :start_os_process, fn _run, _argv -> {:error, :dispatch_disabled} end)
    expect(Tools, :start_os_process, fn _run, _argv -> {:error, :unavailable} end)

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")
    allow(Git, self(), view.pid)
    allow(Tools, self(), view.pid)

    render_async(view)
    view |> element("#issue-start-plan") |> render_click()
    assert has_element?(view, "#flash-error", "Could not create the worktree: no checkout")

    view |> element("#issue-start-plan") |> render_click()
    assert has_element?(view, "#flash-error", "Could not create the worktree: {:github_api_error, 503}")

    view |> element("#issue-start-plan") |> render_click()
    assert has_element?(view, "#flash-error", "Could not start the agent: :enoent")

    assert {:ok, dispatch_view, _html} = live(conn, ~p"/issues/#{dispatch_issue.identifier}")
    allow(Git, self(), dispatch_view.pid)
    allow(Tools, self(), dispatch_view.pid)

    render_async(dispatch_view)
    dispatch_view |> element("#issue-start-plan") |> render_click()
    assert has_element?(dispatch_view, "#flash-error", "Dispatch is switched off, so no agent was started.")

    assert {:ok, other_view, _html} = live(conn, ~p"/issues/#{other_issue.identifier}")
    allow(Git, self(), other_view.pid)
    allow(Tools, self(), other_view.pid)

    render_async(other_view)
    other_view |> element("#issue-start-plan") |> render_click()
    assert has_element?(other_view, "#flash-error", "Could not start: :unavailable")
  end

  test "a failed assignment or comment says so", %{conn: conn, user: user, project: project} do
    {:ok, teammate} =
      Users.register_oauth_user(%{
        github_id: "gh_issue_failing",
        login: "failing_teammate",
        name: "Failing Teammate",
        email: "failing_teammate@example.com"
      })

    teammate |> Ecto.Changeset.change(project_ids: [project.id]) |> Repo.update!()

    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-14",
        title: "Stubborn",
        state: :todo
      })
      |> Repo.insert!()

    %Comment{}
    |> Comment.changeset(%{issue_id: issue.id, author_user_id: user.id, body: "Mine"})
    |> Repo.insert!()

    expect(Issues, :update_issue, fn issue, attrs -> {:error, Issue.tracker_changeset(issue, attrs)} end)

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")
    allow(Issues, self(), view.pid)

    assert has_element?(view, "#issue-comments", "Issue Live")

    view |> element("#issue-assign-#{teammate.id}") |> render_click()
    assert has_element?(view, "#flash-error", "Could not change the assignee")

    view |> element("#issue-comment-form") |> render_change(%{"body" => "draft"})

    view
    |> element("#issue-comment-form")
    |> render_submit(%{"body" => "An orphan", "parent_id" => "com_missing"})

    assert has_element?(view, "#flash-error", "Could not post the comment")
  end

  test "someone without GitHub reads the issue with nothing to change, comment on or start", %{
    conn: conn,
    user: user,
    project: project
  } do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-91",
        title: "Needs GitHub",
        state: :todo
      })
      |> Repo.insert!()

    {:ok, _user} = Users.unlink_github(Scope.for_user(user))

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    assert has_element?(view, "#issue-title", "Needs GitHub")
    assert has_element?(view, "#issue-github-required", "to change, comment on or start this issue")
    assert has_element?(view, "#issue-github-required a[href='/settings/connected-accounts']")
    assert has_element?(view, "#issue-not-started", "Not started")
    refute has_element?(view, "#issue-title-#{issue.id}")
    refute has_element?(view, "#issue-comment-form")
    refute has_element?(view, "#issue-start-plan")
  end

  test "someone without GitHub changes nothing on the issue, whatever events the page is sent", %{
    conn: conn,
    user: user,
    project: project
  } do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-93",
        title: "Untouched",
        state: :todo
      })
      |> Repo.insert!()

    {:ok, _user} = Users.unlink_github(Scope.for_user(user))
    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    render_hook(view, "comment", %{"body" => "Sent anyway"})
    render_hook(view, "edit_issue", %{"title" => "Renamed anyway"})
    render_hook(view, "assign", %{"user_id" => user.id})
    render_hook(view, "start_task", %{})

    assert has_element?(view, "#flash-error", "Connect GitHub in Connected accounts to work on this issue.")

    assert %Issue{title: "Untouched", owner_user_id: nil} = Repo.get!(Issue, issue.id)
    assert Repo.all(from(c in Comment, where: c.issue_id == ^issue.id)) == []
    assert Repo.all(from(t in Task, where: t.issue_id == ^issue.id)) == []
  end

  test "an open issue page turns read-only when its person disconnects GitHub and back when they reconnect", %{
    conn: conn,
    user: user,
    project: project
  } do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-92",
        title: "Needs GitHub",
        state: :todo
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    send(view.pid, {:users_changed, "usr_someone_else"})
    assert has_element?(view, "#issue-comment-form")
    refute has_element?(view, "#issue-github-required")

    {:ok, user} = Users.unlink_github(Scope.for_user(user))

    eventually(fn ->
      assert has_element?(view, "#issue-github-required")
      refute has_element?(view, "#issue-comment-form")
    end)

    auth = %Ueberauth.Auth{
      uid: "relinked_#{user.id}",
      info: %Ueberauth.Auth.Info{nickname: "relinked-#{user.id}", name: "Relinked"},
      credentials: %Ueberauth.Auth.Credentials{token: "gho_relinked"}
    }

    {:ok, _linked} = Users.link_github(Scope.for_user(user), auth)

    eventually(fn ->
      assert has_element?(view, "#issue-comment-form")
      refute has_element?(view, "#issue-github-required")
    end)
  end

  test "reloads when it or its own comments change", %{conn: conn, project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "IPG-15",
        title: "Before the change",
        state: :todo
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")
    # The page's pull request check reloads the issue when it lands, so it lands before the edit.
    render_async(view)

    issue |> Ecto.Changeset.change(title: "After the change") |> Repo.update!()

    send(view.pid, {:issue_changed, "iss_other"})
    send(view.pid, {:issue_comments_changed, "iss_other"})
    send(view.pid, {:issue_created, "iss_other"})
    assert has_element?(view, "#issue-title-#{issue.id}[data-saved='Before the change']")

    send(view.pid, {:issue_comments_changed, issue.id})
    assert has_element?(view, "#issue-title-#{issue.id}[data-saved='After the change']")
  end

  test "an unknown issue goes back to the list", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/issues", flash: %{"error" => "Issue not found"}}}} =
             live(conn, ~p"/issues/iss_missing")
  end

  test "an issue in a project the user cannot access is not found, and shows nothing of it", %{conn: conn} do
    {:ok, other_project} =
      Projects.create_project(system_scope(), %{
        name: "Hidden Project",
        github_repo: "example/hidden-issue",
        github_installation_id: 557,
        key: "HID",
        default_branch: "main",
        clone_path: "/tmp/hidden-issue"
      })

    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: other_project.id,
        identifier: "HID-1",
        title: "A secret title",
        state: :todo
      })
      |> Repo.insert!()

    for path <- [~p"/issues/#{issue.identifier}", ~p"/issues/#{issue.id}"] do
      assert {:error, {:live_redirect, %{to: "/issues", flash: %{"error" => "Issue not found"}}}} = live(conn, path)
    end

    dead = get(conn, ~p"/issues/#{issue.identifier}")
    assert redirected_to(dead) == "/issues"
    refute dead.resp_body =~ "A secret title"
  end

  describe "parents, sub-issues and blockers" do
    setup %{project: project} do
      insert = fn identifier, attrs ->
        %Issue{}
        |> Issue.tracker_changeset(
          Map.merge(
            %{
              project_id: project.id,
              identifier: identifier,
              title: "Title #{identifier}",
              state: :todo
            },
            attrs
          )
        )
        |> Repo.insert!()
      end

      parent = insert.("REL-1", %{})

      %{
        insert: insert,
        parent: parent,
        done_child: insert.("REL-2", %{parent_id: parent.id, state: :done}),
        open_child: insert.("REL-3", %{parent_id: parent.id, state: :in_review})
      }
    end

    test "a parent lists its sub-issues with their done count, and what blocks it and what it blocks", %{
      conn: conn,
      parent: parent,
      open_child: open_child
    } do
      blocker = %Issue{identifier: "REL-9", title: "Blocking", state: :todo, id: "iss_rel_b"}

      finished = %Issue{
        identifier: "REL-8",
        title: "Was blocking",
        state: :done,
        id: "iss_rel_f"
      }

      elsewhere = %Issue{
        identifier: "OTH-1",
        state: :in_progress,
        url: "https://rail.test/issues/iss_oth1"
      }

      waiting = %Issue{identifier: "REL-7", title: "Waiting", state: :todo, id: "iss_rel_w"}

      stub(Issues, :get_blockers, fn [%Issue{id: id}] when id == parent.id ->
        %{
          parent.id => %{
            blocked_by: [
              %{issue: blocker, in_project: true},
              %{issue: elsewhere, in_project: false},
              %{issue: finished, in_project: true}
            ],
            blocks: [%{issue: waiting, in_project: true}]
          }
        }
      end)

      {:ok, view, _html} = live(conn, ~p"/issues/#{parent.identifier}")
      render_async(view)

      refute has_element?(view, "#issue-parent-link")
      assert has_element?(view, "#issue-sub-issues", "1/2")
      assert has_element?(view, "#issue-sub-issues a[href='/issues/#{open_child.identifier}']", "In Review")
      assert has_element?(view, "#issue-blocked-by h2", "2")
      assert has_element?(view, "#issue-blocked-by a[href='/issues/REL-9']", "Blocking")
      assert has_element?(view, "#issue-blocked-by a[href='https://rail.test/issues/iss_oth1']", "In another project")
      assert has_element?(view, "#issue-blocked-by a[href='/issues/REL-8'] .text-slate-500", "Was blocking")
      assert has_element?(view, "#issue-blocks a[href='/issues/REL-7']", "Waiting")
    end

    test "a sub-issue links its parent and shows no empty sections", %{conn: conn, parent: parent, open_child: open_child} do
      # Blockers that fail to read leave their sections out and nothing else.
      stub(Issues, :get_blockers, fn _issues -> raise "The blockers are down" end)

      {:ok, view, _html} = live(conn, ~p"/issues/#{open_child.identifier}")
      render_async(view)

      assert has_element?(view, "#issue-parent-link[title='Title REL-1'][href='/issues/#{parent.identifier}']", "REL-1")
      assert has_element?(view, "#issue-status .text-emerald-500")
      refute has_element?(view, "#issue-sub-issues")
      refute has_element?(view, "#issue-blocked-by")
      refute has_element?(view, "#issue-blocks")
    end

    test "a sub-issue changing or a new one arriving updates the parent's open page", %{
      conn: conn,
      project: project,
      parent: parent,
      open_child: open_child
    } do
      {:ok, view, _html} = live(conn, ~p"/issues/#{parent.identifier}")
      render_async(view)
      assert has_element?(view, "#issue-sub-issues", "1/2")

      assert {:ok, _issue} =
               Issues.set_issue_status(system_scope(), open_child, %{id: "done", name: "Done", state: :done})

      assert has_element?(view, "#issue-sub-issues", "2/2")

      assert {:ok, %Issue{identifier: identifier}} =
               Issues.create_issue(system_scope(), project, %{title: "Another part", parent: parent})

      assert has_element?(view, "#issue-sub-issues", "2/3")
      assert has_element?(view, "#issue-sub-issues a[href='/issues/#{identifier}']")
    end

    test "a blocker finishing reads blockers again", %{conn: conn, parent: parent, insert: insert} do
      blocker = insert.("REL-5", %{})
      test_pid = self()

      stub(Issues, :get_blockers, fn [issue] ->
        send(test_pid, :blockers_read)
        %{issue.id => %{blocked_by: [%{issue: Repo.get!(Issue, blocker.id), in_project: true}], blocks: []}}
      end)

      {:ok, view, _html} = live(conn, ~p"/issues/#{parent.identifier}")
      render_async(view)
      assert_received :blockers_read
      assert has_element?(view, "#issue-blocked-by h2", "1")

      assert {:ok, _issue} = Issues.set_issue_status(system_scope(), blocker, %{id: "done", name: "Done", state: :done})

      render_async(view)
      assert_received :blockers_read
      assert has_element?(view, "#issue-blocked-by h2", "0")

      # An unrelated issue changing reads neither the issue nor its blockers.
      unrelated = insert.("REL-6", %{})
      send(view.pid, {:issue_changed, unrelated.id})
      render_async(view)
      refute_received :blockers_read
    end
  end

  describe "editing an issue" do
    setup %{user: user, project: project} do
      key = "Edp#{System.unique_integer([:positive])}"

      {:ok, local} =
        Projects.create_project(system_scope(), %{
          name: "Edited in place",
          github_repo: "example/#{key}",
          github_installation_id: 1,
          key: key,
          default_branch: "main",
          clone_path: "/tmp/#{key}"
        })

      {:ok, _user} = Users.update_user(system_scope(), user, %{project_ids: [project.id, local.id]})
      {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "Filed as it was", description: "Old"})
      # Blockers come from Rail's own relations here, so they are read for real.
      stub(Issues, :get_blockers, fn issues -> call_original(Issues, :get_blockers, [issues]) end)

      %{local: local, issue: issue}
    end

    test "the title, priority and estimate save as they are picked, and every open page shows them", %{
      conn: conn,
      issue: %Issue{id: issue_id}
    } do
      {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
      {:ok, second, _html} = live(conn, ~p"/issues/#{issue_id}")

      assert has_element?(view, "#issue-title-#{issue_id}[contenteditable='true'][data-saved='Filed as it was']")

      view |> element("#issue-title-#{issue_id}") |> render_hook("edit_issue", %{"title" => "Renamed in place"})
      view |> element("#issue-priority-urgent") |> render_click()
      view |> element("#issue-estimate-8") |> render_click()

      assert %Issue{title: "Renamed in place", priority: :urgent, estimate: 8} = Repo.get!(Issue, issue_id)
      assert has_element?(second, "#issue-title-#{issue_id}[data-saved='Renamed in place']")
      assert has_element?(second, "#issue-priority", "Urgent")
      assert has_element?(second, "#issue-estimate", "8 Points")

      view |> element("#issue-estimate-none") |> render_click()
      assert has_element?(second, "#issue-estimate", "No points")
    end

    test "the priority and estimate menus move with the arrow keys, and Escape on an item hands focus back", %{
      conn: conn,
      issue: %Issue{id: issue_id}
    } do
      {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")

      for {menu, item} <- [{"issue-priority", "urgent"}, {"issue-estimate", "none"}] do
        assert has_element?(view, "##{menu}-menu[phx-hook='MenuKeys']")

        assert has_element?(
                 view,
                 ~s(##{menu}-#{item}[phx-key='Escape'][phx-keydown*='"focus",{"to":"##{menu}"}'])
               )
      end
    end

    test "an emptied title saves nothing, and the page keeps the saved one", %{conn: conn, issue: %Issue{id: issue_id}} do
      {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")

      view |> element("#issue-title-#{issue_id}") |> render_hook("edit_issue", %{"title" => "  "})

      assert %Issue{title: "Filed as it was"} = Repo.get!(Issue, issue_id)
      assert has_element?(view, "#issue-title-#{issue_id}[data-saved='Filed as it was']")
    end

    test "only the title, priority and estimate are taken from the page's event", %{
      conn: conn,
      issue: %Issue{id: issue_id}
    } do
      {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")

      view
      |> element("#issue-title-#{issue_id}")
      |> render_hook("edit_issue", %{"title" => "Renamed", "description" => "Overwritten"})

      assert %Issue{title: "Renamed", description: "Old"} = Repo.get!(Issue, issue_id)
    end

    test "an estimate the menu does not offer is shown as it is, in its place", %{
      conn: conn,
      issue: %Issue{id: issue_id} = issue
    } do
      {:ok, _issue} = Issues.edit_issue(system_scope(), issue, %{"estimate" => "4"})
      {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")

      assert has_element?(view, "#issue-estimate", "4 Points")
      assert has_element?(view, "#issue-estimate-menu li:nth-child(5) #issue-estimate-4")
      assert has_element?(view, "#issue-estimate-1", "1 Point")
    end

    test "a parent is searched for and set, the breadcrumb and its Sub-issues follow, and clearing removes both", %{
      conn: conn,
      local: local,
      issue: %Issue{id: issue_id} = issue
    } do
      {:ok, %Issue{id: parent_id, identifier: parent_identifier}} =
        Issues.create_issue(system_scope(), local, %{title: "Review sends one round"})

      {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
      {:ok, parent_page, _html} = live(conn, ~p"/issues/#{parent_id}")
      picker = "#issue-parent-picker-#{issue_id}"

      assert has_element?(view, "#issue-parent", "No parent")
      view |> element("#issue-parent") |> render_click()
      view |> form("#{picker}-search-form", %{q: "one round"}) |> render_change()
      view |> element("#{picker}-issue-#{parent_id}") |> render_click()

      assert has_element?(view, "#issue-parent-link", parent_identifier)
      assert has_element?(view, "#issue-parent", "Review sends one round")
      refute has_element?(view, "#{picker}-menu")
      assert has_element?(parent_page, "#issue-sub-issues-#{issue.identifier}")

      view |> element("#issue-parent") |> render_click()
      view |> element("#{picker}-none") |> render_click()

      refute has_element?(view, "#issue-parent-link")
      refute has_element?(parent_page, "#issue-sub-issues")
    end

    test "the issue and its direct sub-issues are not offered as its parent, and one further down is refused", %{
      conn: conn,
      local: local,
      issue: %Issue{id: issue_id} = issue
    } do
      {:ok, %Issue{id: child_id} = child} = Issues.create_issue(system_scope(), local, %{title: "Child", parent: issue})

      {:ok, %Issue{id: grandchild_id, identifier: grandchild_identifier}} =
        Issues.create_issue(system_scope(), local, %{title: "Grandchild", parent: child})

      {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
      picker = "#issue-parent-picker-#{issue_id}"
      view |> element("#issue-parent") |> render_click()

      refute has_element?(view, "#{picker}-issue-#{issue_id}")
      refute has_element?(view, "#{picker}-issue-#{child_id}")
      view |> element("#{picker}-issue-#{grandchild_id}") |> render_click()

      assert has_element?(view, "#{picker}-error", "#{grandchild_identifier} is a sub-issue of this issue")
      assert %Issue{parent_id: nil} = Repo.get!(Issue, issue_id)

      # Escape closes the menu and its reason.
      view |> element(picker) |> render_keydown(%{"key" => "Escape"})
      refute has_element?(view, "#{picker}-menu")
    end

    test "a blocker added on one issue shows on both pages without a reload, and removing it clears both", %{
      conn: conn,
      local: local,
      issue: %Issue{id: issue_id, identifier: identifier}
    } do
      {:ok, %Issue{id: blocker_id, identifier: blocker_identifier}} =
        Issues.create_issue(system_scope(), local, %{title: "Goes first"})

      {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
      {:ok, blocker_page, _html} = live(conn, ~p"/issues/#{blocker_id}")
      render_async(view)
      picker = "#issue-blocked-by-picker-#{issue_id}"

      view |> element("#{picker}-trigger") |> render_click()
      refute has_element?(view, "#{picker}-issue-#{issue_id}")
      view |> element("#{picker}-issue-#{blocker_id}") |> render_click()

      render_async(view)
      render_async(blocker_page)
      assert has_element?(view, "#issue-blocked-by-#{blocker_identifier}", "Goes first")
      assert has_element?(blocker_page, "#issue-blocks-#{identifier}", "Filed as it was")

      # Related either way, so neither picker offers it again.
      view |> element("#issue-blocks-picker-#{issue_id}-trigger") |> render_click()
      refute has_element?(view, "#issue-blocks-picker-#{issue_id}-issue-#{blocker_id}")

      blocker_page |> element("#issue-blocks-#{identifier}-remove") |> render_click()

      render_async(view)
      render_async(blocker_page)
      refute has_element?(view, "#issue-blocked-by")
      refute has_element?(blocker_page, "#issue-blocks")
    end

    test "a relation naming an issue the page does not show removes nothing", %{
      conn: conn,
      local: local,
      issue: %Issue{id: issue_id} = issue
    } do
      {:ok, first} = Issues.create_issue(system_scope(), local, %{title: "First"})
      {:ok, second} = Issues.create_issue(system_scope(), local, %{title: "Second"})
      :ok = Issues.block_issue(system_scope(), first, second)
      :ok = Issues.block_issue(system_scope(), first, issue)

      {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
      render_async(view)

      render_click(view, "remove_relation", %{"blocker_id" => first.id, "blocked_id" => second.id})
      render_click(view, "remove_relation", %{"blocker_id" => "iss_missing", "blocked_id" => issue_id})

      assert %{blocked_by: [], blocks: [_second, _issue]} =
               Issues.get_blockers([%{first | project: local}])[first.id]
    end

    test "a link triage made is listed once and opens in a new tab", %{conn: conn, issue: %Issue{id: issue_id}} do
      args = %{issue_id: issue_id, url: "https://dishbooks.slack.com/archives/C07/p17", title: "Slack thread"}
      {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")

      assert :ok = perform_job(LinkTrackerUrl, args)
      assert :ok = perform_job(LinkTrackerUrl, args)

      assert [_link] =
               view
               |> render()
               |> Floki.parse_document!()
               |> Floki.find("a[href='https://dishbooks.slack.com/archives/C07/p17'][target='_blank']")

      assert has_element?(view, "a[href='https://dishbooks.slack.com/archives/C07/p17'] .pi-slack-logo")
      assert has_element?(view, "a[href='https://dishbooks.slack.com/archives/C07/p17']", "Slack thread")

      assert :ok = perform_job(LinkTrackerUrl, %{args | url: "https://example.com/doc", title: "Doc"})
      assert has_element?(view, "a[href='https://example.com/doc'] .pi-link-simple")
    end
  end

  describe "an issue's cycle" do
    setup %{conn: conn, user: user, project: project} do
      key = "IPC#{System.unique_integer([:positive])}"

      {:ok, local} =
        Projects.create_project(system_scope(), %{
          name: "Issue page cycles",
          github_repo: "example/#{key}",
          github_installation_id: 1,
          key: key,
          default_branch: "main",
          clone_path: "/tmp/#{key}"
        })

      {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id, local.id]})
      {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "Planned from its page"})
      %{conn: log_in_user(conn, user), local: local, issue: issue}
    end

    test "the menu offers no cycle and those not ended, and a pick moves the issue onto an Issues page open on it", %{
      conn: conn,
      local: local,
      issue: %{id: issue_id}
    } do
      # Cycle 1 ran Nov 10 to 23, Cycle 2 runs now, and Cycles 3 and 4 are next.
      :ok = Issues.close_cycle_day(~D[2026-11-10])
      stub(Date, :utc_today, fn -> ~D[2026-11-24] end)
      :ok = Issues.close_cycle_day(~D[2026-11-24])
      {:ok, %{cycles: [first, second, third, fourth]}} = Issues.get_cycles(local)

      {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
      {:ok, list, _html} = live(init_test_session(conn, %{selected_project_id: local.id}), ~p"/issues?cycle=2")
      render_async(list)

      assert has_element?(view, "#issue-cycle", "No cycle")
      refute has_element?(view, "#issue-cycle-#{first.id}")
      assert has_element?(view, "#issue-cycle-#{second.id}", "Current · Nov 24 – Dec 7")
      assert has_element?(view, "#issue-cycle-#{third.id}", "Dec 8 – Dec 21")
      assert has_element?(view, "#issue-cycle-#{fourth.id}", "Cycle 4")
      refute has_element?(list, "#issue-card-#{issue_id}")
      assert has_element?(view, ~s(#issue-cycle-none[phx-click*='"focus",{"to":"#issue-cycle"}']))
      assert has_element?(view, ~s(#issue-cycle-#{second.id}[phx-click*='"focus",{"to":"#issue-cycle"}']))

      view |> element("#issue-cycle-#{second.id}") |> render_click()
      assert has_element?(view, "#issue-cycle", "Cycle 2")
      assert has_element?(list, "#issue-card-#{issue_id}")

      view |> element("#issue-cycle-none") |> render_click()
      assert has_element?(view, "#issue-cycle", "No cycle")
      refute has_element?(list, "#issue-card-#{issue_id}")

      render_hook(view, "set_cycle", %{"cycle_id" => first.id})
      assert render(view) =~ "Could not change the cycle"
    end

    test "the nightly run's rollover shows on its open page without a reload", %{
      conn: conn,
      local: local,
      issue: %{id: issue_id} = issue
    } do
      :ok = Issues.close_cycle_day(~D[2026-11-10])
      stub(Date, :utc_today, fn -> ~D[2026-11-12] end)
      {:ok, %{cycles: [first | _later]}} = Issues.get_cycles(local)
      {:ok, _issue} = Issues.set_issue_cycle(system_scope(), issue, first.id)

      {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
      assert has_element?(view, "#issue-cycle", "Cycle 1")

      stub(Date, :utc_today, fn -> ~D[2026-11-24] end)
      :ok = Issues.close_cycle_day(~D[2026-11-24])

      assert has_element?(view, "#issue-cycle", "Cycle 2")
      assert has_element?(view, "#issue-cycle", "Nov 24 – Dec 7")
    end

    test "the menu moves with the arrow keys, opens on an item, and Escape on an item hands focus back", %{
      conn: conn,
      issue: %{id: issue_id}
    } do
      {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")

      assert has_element?(view, "#issue-cycle-menu[phx-hook='MenuKeys']")
      assert has_element?(view, ~s(#issue-cycle[phx-click*='"focus_first",{"to":"#issue-cycle-menu"}']))
      assert has_element?(view, ~s(#issue-cycle-none[phx-key='Escape'][phx-keydown*='"focus",{"to":"#issue-cycle"}']))
    end

    test "another project's cycles leave the page as it is", %{conn: conn, issue: %{id: issue_id}} do
      {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
      send(view.pid, {:cycles_changed, "prj_elsewhere"})
      assert has_element?(view, "#issue-cycle", "No cycle")
    end
  end

  describe "an issue's initiative" do
    setup %{conn: conn, user: user, project: project} do
      key = "IPI#{System.unique_integer([:positive])}"

      {:ok, local} =
        Projects.create_project(system_scope(), %{
          name: "Dishbooks",
          github_repo: "example/#{key}",
          github_installation_id: 1,
          key: key,
          default_branch: "main",
          clone_path: "/tmp/#{key}"
        })

      {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id, local.id]})
      stub(Date, :utc_today, fn -> ~D[2026-11-23] end)

      {:ok, credo} =
        Rail.Initiatives.create_initiative(system_scope(), local, %{name: "Credo exclusions", expected_on: ~D[2026-12-12]})

      {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "DIS-2364"})
      {:ok, done} = Issues.create_issue(system_scope(), local, %{title: "DIS-2363"})
      {:ok, done} = Issues.set_issue_initiative(system_scope(), done, credo.id)
      {:ok, _done} = Issues.set_issue_status(system_scope(), done, %{id: "done", name: "Done", state: :done})
      %{conn: log_in_user(conn, user), local: local, issue: issue, credo: credo}
    end

    test "the menu offers only the project's initiatives, and a pick shows its name, percent and link", %{
      conn: conn,
      local: local,
      issue: %{id: issue_id},
      credo: %{id: credo_id} = credo,
      github_project: other
    } do
      {:ok, today} =
        Rail.Initiatives.create_initiative(system_scope(), local, %{name: "Square POS", expected_on: ~D[2026-11-23]})

      {:ok, late} =
        Rail.Initiatives.create_initiative(system_scope(), local, %{name: "Bank feeds", expected_on: ~D[2026-11-20]})

      {:ok, none} = Rail.Initiatives.create_initiative(system_scope(), local, %{name: "Payroll v2"})
      {:ok, elsewhere} = Rail.Initiatives.create_initiative(system_scope(), other, %{name: "Elsewhere #{local.key}"})

      {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
      render_async(view)

      assert has_element?(view, "#issue-initiative", "No initiative")
      refute has_element?(view, "#issue-initiative-link")
      assert has_element?(view, "#issue-initiative-#{credo.id}", "1 of 1 · Dec 12")
      assert has_element?(view, "#issue-initiative-#{today.id}", "0 of 0 · Due today")
      assert has_element?(view, "#issue-initiative-#{late.id}", "0 of 0 · 3 days late")
      assert has_element?(view, "#issue-initiative-#{none.id}", "0 of 0")
      refute has_element?(view, "#issue-initiative-#{elsewhere.id}")
      assert has_element?(view, "#issue-initiative-menu", "Initiatives in Dishbooks")
      assert has_element?(view, "#issue-initiative-menu[phx-hook='MenuKeys']")

      assert has_element?(
               view,
               ~s(#issue-initiative-none[phx-key='Escape'][phx-keydown*='"focus",{"to":"#issue-initiative"}'])
             )

      view |> element("#issue-initiative-#{credo.id}") |> render_click()

      assert has_element?(view, "#issue-initiative", "Credo exclusions")
      assert has_element?(view, "#issue-initiative", "50%")

      assert has_element?(
               view,
               "#issue-initiative-link[href='/initiatives/#{credo.id}'][aria-label='Open Credo exclusions']"
             )

      assert %Issue{initiative_id: ^credo_id} = Repo.get!(Issue, issue_id)

      view |> element("#issue-initiative-none") |> render_click()
      assert has_element?(view, "#issue-initiative", "No initiative")

      render_hook(view, "set_initiative", %{"initiative_id" => elsewhere.id})
      assert render(view) =~ "Could not change the initiative"
      assert %Issue{initiative_id: nil} = Repo.get!(Issue, issue_id)
    end

    test "its percent moves as the issue is done on its page, and deleting the initiative reads No initiative", %{
      conn: conn,
      issue: %{id: issue_id} = issue,
      credo: credo
    } do
      {:ok, _issue} = Issues.set_issue_initiative(system_scope(), issue, credo.id)
      {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
      render_async(view)
      assert has_element?(view, "#issue-initiative", "50%")

      view |> element("#issue-status") |> render_click()
      render_async(view)
      view |> element("#issue-status-picker-#{issue_id}-status-done") |> render_click()
      assert has_element?(view, "#issue-initiative", "100%")

      :ok = Rail.Initiatives.delete_initiative(system_scope(), credo)
      assert has_element?(view, "#issue-initiative", "No initiative")
      refute has_element?(view, "#issue-initiative-#{credo.id}")
    end

    test "a rename shows without a reload, and another project's initiatives leave the page as it is", %{
      conn: conn,
      issue: %{id: issue_id} = issue,
      credo: credo
    } do
      {:ok, _issue} = Issues.set_issue_initiative(system_scope(), issue, credo.id)
      {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
      render_async(view)

      {:ok, _renamed} = Rail.Initiatives.update_initiative(system_scope(), credo, %{name: "Credo cleanup"})
      assert has_element?(view, "#issue-initiative", "Credo cleanup")

      send(view.pid, {:initiatives_changed, "prj_elsewhere"})
      assert has_element?(view, "#issue-initiative", "Credo cleanup")
    end

    test "someone without GitHub reads the issue's initiative with no menu or link", %{
      conn: conn,
      user: user,
      issue: %{id: issue_id} = issue,
      credo: credo
    } do
      {:ok, _issue} = Issues.set_issue_initiative(system_scope(), issue, credo.id)
      {:ok, _user} = Users.unlink_github(Scope.for_user(user))

      {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
      render_async(view)

      assert has_element?(view, "#issue-initiative", "Credo exclusions")
      assert has_element?(view, "#issue-initiative", "50%")
      refute has_element?(view, "#issue-initiative-menu")
      refute has_element?(view, "#issue-initiative-link")
    end
  end
end
