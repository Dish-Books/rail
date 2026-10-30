defmodule RailWeb.IssueLiveTest do
  use RailWeb.ConnCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Phoenix.LiveViewTest

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.AdvanceTrackerState
  alias Rail.Issues.Workers.LinearSync
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users
  alias Rail.Workflows.Schemas.Workflow
  alias Rail.Workflows.Schemas.WorkflowDefinition

  setup %{conn: conn, project: project} do
    # A role's prompt is read from the project's clone, which another test may have made, so reading it here
    # would spawn git: these see no prompt file on the default branch, as when there is no clone. A task Linear
    # deletes takes its worktree and branch in that clone with it.
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
    # Blockers are read from Linear, which no test here asks unless it says.
    stub(Issues, :get_blockers, fn _issues -> %{} end)

    %{conn: log_in_user(conn, user), user: user, project: project}
  end

  test "shows the issue's title, description and properties", %{conn: conn, user: user, project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        owner_user_id: user.id,
        external_id: "lin_page_1",
        identifier: "IPG-7",
        title: "AP Aging exports to PDF",
        description: "The report offers **one** export.",
        priority: :high,
        estimate: 2,
        state: :in_progress,
        state_name: "In Progress",
        branch_name: "ipg-7-ap-aging",
        url: "https://linear.app/issue/IPG-7"
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    assert has_element?(view, "#issue-identifier", "IPG-7")
    assert has_element?(view, "#issue-title", "AP Aging exports to PDF")
    assert has_element?(view, "#issue-description strong", "one")
    assert has_element?(view, "#issue-status", "In Progress")
    assert has_element?(view, "#issue-priority", "High")
    assert has_element?(view, "#issue-owner", "Issue Live")
    assert has_element?(view, "#issue-estimate", "2 Points")
    assert has_element?(view, "#issue-project", "Test Project")
    assert has_element?(view, "#issue-tracker-link[href='https://linear.app/issue/IPG-7']")
    assert has_element?(view, "#issue-branch[phx-hook='CopyText'][data-copy-text='ipg-7-ap-aging']")
  end

  test "an issue a workflow opened names it under the title, as plain text for someone who is not an admin", %{
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
        external_id: "lin_workflow_page_1",
        identifier: "WFP-1",
        title: "Flaky test sweep 2026-10-12",
        state: :triage
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    assert has_element?(view, "#issue-workflow-byline", "Opened by the Flaky test sweep workflow on Oct 12, 08:00 UTC")
    refute has_element?(view, "#issue-workflow-link")
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
          external_id: "lin_workflow_page_admin_#{n}",
          identifier: "WFA-#{n}",
          title: "Admin #{n}",
          state: :triage
        })
        |> Repo.insert!()
      end

    admin_conn = log_in_user(conn, Repo.reload!(admin))

    assert {:ok, view, _html} = live(admin_conn, ~p"/issues/#{opened.identifier}")
    assert has_element?(view, ~s(#issue-workflow-link[href="/settings/workflows"]), "Sweep")

    assert {:ok, view, _html} = live(admin_conn, ~p"/issues/#{filed.identifier}")
    refute has_element?(view, "#issue-workflow-byline")
  end

  test "a GitHub issue opens from its key#number identifier, and anyone can own it", %{
    conn: conn,
    user: user,
    github_project: project
  } do
    {:ok, _user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    issue = github_issue(project, %{number: 42, identifier: "tgh#42", title: "Hash in the name"})

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    assert has_element?(view, "#issue-identifier", "tgh#42")
    assert has_element?(view, "#issue-title", "Hash in the name")
    assert has_element?(view, "#issue-assign-#{user.id}")
  end

  test "the assignee can be changed to a Linear-linked user, or cleared", %{conn: conn, user: user, project: project} do
    {:ok, %{id: teammate_id} = teammate} =
      Users.register_oauth_user(%{
        github_id: "gh_issue_teammate",
        login: "teammate",
        name: "Paulo Teammate",
        email: "teammate@example.com"
      })

    teammate |> Ecto.Changeset.change(linear_user_id: "lin_usr_teammate", project_ids: [project.id]) |> Repo.update!()

    # Only people who can open the issue are offered: admins and those granted its project.
    linked = fn login, attrs ->
      {:ok, other} =
        Users.register_oauth_user(%{
          github_id: "gh_#{login}_issue-live",
          login: "#{login}-issue-live",
          name: login,
          email: "#{login}-issue-live@example.com"
        })

      other |> Ecto.Changeset.change(Map.put(attrs, :linear_user_id, "lin_#{login}")) |> Repo.update!()
    end

    elsewhere = linked.("elsewhere", %{project_ids: ["prj_other"]})
    admin = linked.("admin", %{admin: true})

    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_page_3",
        identifier: "IPG-9",
        title: "Assign me",
        state: :todo
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    assert has_element?(view, "#issue-estimate", "No points")

    # Only users who linked Linear are offered; the signed-in user has not.
    refute has_element?(view, "#issue-assign-#{user.id}")
    refute has_element?(view, "#issue-assign-#{elsewhere.id}")
    assert has_element?(view, "#issue-assign-#{admin.id}")

    view |> element("#issue-owner-search-form") |> render_change(%{"q" => "nobody"})
    refute has_element?(view, "#issue-assign-#{teammate.id}")

    view |> element("#issue-owner-search-form") |> render_change(%{"q" => "paulo"})
    view |> element("#issue-assign-#{teammate.id}") |> render_click()

    assert has_element?(view, "#issue-owner", "Paulo Teammate")
    assert %Issue{owner_user_id: ^teammate_id} = Repo.get!(Issue, issue.id)
    assert_enqueued(worker: SyncIssue, args: %{issue_id: issue.id, fields: ["owner_user_id"]})
    # It had no owner, so its Linear status was held back and now catches up with its task.
    assert_enqueued(worker: AdvanceTrackerState, args: %{issue_id: issue.id})

    view |> element("#issue-assign-none") |> render_click()

    assert has_element?(view, "#issue-owner", "Unassigned")
    assert %Issue{owner_user_id: nil} = Repo.get!(Issue, issue.id)
  end

  test "the task link reads the latest run at the task's stage, not one it retried", %{
    conn: conn,
    project: project
  } do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_page_retry",
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
        external_id: "lin_page_review_waiting",
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

  test "an issue with no task can be started from its page", %{conn: conn, project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_page_2",
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

    assert has_element?(view, "#issue-description", "No description")
    assert has_element?(view, "#issue-owner", "Unassigned")
    refute has_element?(view, "#issue-task-link")

    render_async(view)
    view |> element("#issue-start-plan") |> render_click()

    assert %Task{id: task_id, stage: :plan} = Repo.get_by(Task, issue_id: issue.id)
    assert_redirect(view, ~p"/tasks/#{task_id}")
  end

  test "an issue offers one Start at Plan button, where every task begins", %{conn: conn, project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_page_17",
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

  test "an issue whose work has a pull request links it, and offers Review in place of Plan", %{
    conn: conn,
    project: project
  } do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_page_adopt",
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

    view |> element("#issue-start-review") |> render_click()

    assert %Task{id: task_id, stage: :review} = Repo.get_by(Task, issue_id: issue.id)
    assert_redirect(view, ~p"/tasks/#{task_id}")
  end

  test "an issue with a linked pull request offers Review without asking GitHub again", %{
    conn: conn,
    project: project
  } do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_page_linked",
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
    assert has_element?(view, "#issue-pull-request", "Linked")
    refute has_element?(view, "#issue-start-plan")
  end

  test "an issue offers Plan when GitHub has no pull request for it or cannot say", %{conn: conn, project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_page_no_pr",
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
        external_id: "lin_page_adopt_refused",
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

  test "a Duplicate issue reads as Duplicate and offers no start", %{conn: conn, project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_page_dup",
        identifier: "IPG-20",
        title: "Same as IPG-7",
        state: :duplicate,
        state_name: "Duplicate"
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    assert has_element?(view, "#issue-status", "Duplicate")
    refute has_element?(view, "#issue-start")
  end

  test "an open page follows Linear closing its issue and stops offering to start it", %{
    conn: conn,
    project: project
  } do
    {:ok, workspace} = Projects.get_linear_workspace(id: project.linear_workspace_id)

    for {external_id, identifier} <- [{"lin_page_open", "IPG-21"}, {"lin_page_other", "IPG-22"}] do
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: external_id,
        identifier: identifier,
        title: "Open #{identifier}",
        state: :todo,
        state_name: "Todo"
      })
      |> Repo.insert!()
    end

    assert {:ok, view, _html} = live(conn, ~p"/issues/IPG-21")
    assert has_element?(view, "#issue-start")

    duplicate = fn external_id, identifier ->
      %{
        "type" => "Issue",
        "action" => "update",
        "data" => %{
          "id" => external_id,
          "teamId" => "lin_team_id",
          "identifier" => identifier,
          "title" => "Open #{identifier}",
          "state" => %{"id" => "st_dup", "name" => "Duplicate", "type" => "duplicate"}
        }
      }
    end

    # An unrelated issue closing leaves this page as it was.
    assert {:ok, _other} = Issues.handle_linear_webhook(workspace, duplicate.("lin_page_other", "IPG-22"))
    assert has_element?(view, "#issue-status", "Todo")
    assert has_element?(view, "#issue-start")

    assert {:ok, _issue} = Issues.handle_linear_webhook(workspace, duplicate.("lin_page_open", "IPG-21"))
    assert has_element?(view, "#issue-status", "Duplicate")
    refute has_element?(view, "#issue-start")
  end

  test "an issue that cannot be started says why and keeps no task", %{conn: conn, project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_page_6",
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
        external_id: "lin_page_4",
        identifier: "IPG-10",
        title: "Discussed",
        state: :todo
      })
      |> Repo.insert!()

    %Comment{id: thread_id} =
      %Comment{}
      |> Comment.changeset(%{
        issue_id: issue.id,
        external_id: "lin_thread",
        body: "Should all four wait on **DIS-1377**?",
        author_name: "paulo",
        inserted_at: DateTime.shift(DateTime.utc_now(), day: -4)
      })
      |> Repo.insert!()

    %Comment{id: reply_id} =
      %Comment{}
      |> Comment.changeset(%{issue_id: issue.id, parent_id: thread_id, external_id: "lin_reply", body: "yes"})
      |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    assert has_element?(view, "#comment-#{thread_id}", "paulo")
    assert has_element?(view, "#comment-#{thread_id}", "4d ago")
    assert has_element?(view, "#comment-#{thread_id} strong", "DIS-1377")
    assert has_element?(view, "#comment-#{thread_id} #comment-#{reply_id}", "yes")
    assert has_element?(view, "#comment-reply-form-#{thread_id} input[name='parent_id'][value='#{thread_id}']")

    %Comment{id: late_id} =
      %Comment{}
      |> Comment.changeset(%{issue_id: issue.id, external_id: "lin_late", body: "Arrived by webhook"})
      |> Repo.insert!()

    send(view.pid, {:issue_comments_changed, issue.id})

    assert has_element?(view, "#comment-#{late_id}", "Arrived by webhook")
  end

  test "posting a comment and a reply sends them to Linear and shows them", %{conn: conn, project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_page_5",
        identifier: "ICP-1",
        title: "Talk about me",
        state: :todo
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    Req.Test.allow(Rail.Linear, self(), view.pid)

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{"input" => %{"issueId" => "lin_page_5", "body" => "First thought"} = input} =
               Jason.decode!(body)["variables"]

      refute Map.has_key?(input, "parentId")

      Req.Test.json(conn, %{
        "data" => %{
          "commentCreate" => %{
            "success" => true,
            "comment" => %{"id" => "lin_posted", "body" => "First thought", "issue" => %{"id" => "lin_page_5"}}
          }
        }
      })
    end)

    view |> element("#issue-comment-form") |> render_submit(%{"body" => "  First thought  "})

    %Comment{id: thread_id} = Repo.get_by!(Comment, external_id: "lin_posted")
    assert has_element?(view, "#comment-#{thread_id}", "First thought")

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"input" => %{"parentId" => "lin_posted", "body" => "A reply"}} = Jason.decode!(body)["variables"]

      Req.Test.json(conn, %{
        "data" => %{
          "commentCreate" => %{
            "success" => true,
            "comment" => %{
              "id" => "lin_posted_reply",
              "body" => "A reply",
              "issue" => %{"id" => "lin_page_5"},
              "parent" => %{"id" => "lin_posted"}
            }
          }
        }
      })
    end)

    view
    |> element("#comment-reply-form-#{thread_id}")
    |> render_submit(%{"body" => "A reply", "parent_id" => thread_id})

    assert has_element?(view, "#comment-#{thread_id} [id^='comment-com']", "A reply")

    # A blank comment sends nothing; no Linear mock is queued for it.
    view |> element("#issue-comment-form") |> render_submit(%{"body" => "   "})
  end

  test "each reason a start fails is said plainly", %{conn: conn, project: project} do
    [issue, dispatch_issue, other_issue] =
      for n <- [12, 13, 16] do
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: project.id,
          external_id: "lin_page_#{n}",
          identifier: "IPG-#{n}",
          title: "Fails to start",
          state: :todo
        })
        |> Repo.insert!()
      end

    expect(Git, :get_or_create_worktree, fn _project, _task -> {:error, "no checkout"} end)
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

    teammate |> Ecto.Changeset.change(linear_user_id: "lin_usr_failing", project_ids: [project.id]) |> Repo.update!()

    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_page_14",
        identifier: "IPG-14",
        title: "Stubborn",
        state: :todo
      })
      |> Repo.insert!()

    %Comment{}
    |> Comment.changeset(%{issue_id: issue.id, author_user_id: user.id, external_id: "lin_own", body: "Mine"})
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

  test "reloads when its own project syncs or its own comments change", %{conn: conn, project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_page_15",
        identifier: "IPG-15",
        title: "Before sync",
        state: :todo
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    issue |> Ecto.Changeset.change(title: "After sync") |> Repo.update!()

    send(view.pid, {:issues_synced, "prj_other"})
    send(view.pid, {:issue_comments_changed, "iss_other"})
    send(view.pid, {:issue_created, "iss_other"})
    assert has_element?(view, "#issue-title", "Before sync")

    send(view.pid, {:issues_synced, project.id})
    assert has_element?(view, "#issue-title", "After sync")
  end

  test "an open page goes back to Issues once Linear deletes its issue, by webhook or by a sync", %{
    conn: conn,
    project: project
  } do
    {:ok, workspace} = Projects.get_linear_workspace(id: project.linear_workspace_id)

    [deleted, pruned] =
      for {external_id, identifier} <- [{"lin_page_deleted", "IPG-31"}, {"lin_page_pruned", "IPG-32"}] do
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: project.id,
          external_id: external_id,
          identifier: identifier,
          title: "Doomed #{identifier}",
          state: :todo
        })
        |> Repo.insert!()
        |> Repo.preload(:project)
      end

    {:ok, _task} = Pipeline.create_task(deleted, :plan)

    assert {:ok, view, _html} = live(conn, ~p"/issues/IPG-31")

    assert {:ok, %Issue{}} =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Issue",
               "action" => "remove",
               "data" => %{"id" => "lin_page_deleted"}
             })

    assert %{"error" => "Issue not found"} = assert_redirect(view, ~p"/issues")

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{pruned.identifier}")
    started_at = DateTime.to_iso8601(DateTime.utc_now())

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issues" => %{
            "nodes" => [%{"id" => "lin_page_listed", "identifier" => "IPG-33", "title" => "Still listed"}],
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
          }
        }
      })
    end)

    assert :ok = perform_job(LinearSync, %{project_id: project.id, started_at: started_at})
    assert %{"error" => "Issue not found"} = assert_redirect(view, ~p"/issues")
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
        external_id: "lin_hidden_1",
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

      {:ok, workspace} = Projects.get_linear_workspace(id: project.linear_workspace_id)
      parent = insert.("REL-1", %{})

      %{
        insert: insert,
        workspace: workspace,
        parent: parent,
        done_child: insert.("REL-2", %{parent_external_id: parent.external_id, state: :done, state_name: "Done"}),
        open_child:
          insert.("REL-3", %{parent_external_id: parent.external_id, state: :in_progress, state_name: "In Review"})
      }
    end

    test "a parent lists its sub-issues with their done count, and what blocks it and what it blocks", %{
      conn: conn,
      parent: parent,
      open_child: open_child
    } do
      blocker = %Issue{external_id: "lin_rel_b", identifier: "REL-9", title: "Blocking", state: :todo, id: "iss_rel_b"}

      finished = %Issue{
        external_id: "lin_rel_f",
        identifier: "REL-8",
        title: "Was blocking",
        state: :done,
        id: "iss_rel_f"
      }

      elsewhere = %Issue{
        external_id: "lin_oth",
        identifier: "OTH-1",
        state: :in_progress,
        url: "https://linear.app/OTH-1"
      }

      waiting = %Issue{external_id: "lin_rel_w", identifier: "REL-7", title: "Waiting", state: :todo, id: "iss_rel_w"}

      stub(Issues, :get_blockers, fn [%Issue{id: id}] when id == parent.id ->
        %{
          parent.external_id => %{
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
      assert has_element?(view, "#issue-blocked-by a[href='https://linear.app/OTH-1']", "In another project")
      assert has_element?(view, "#issue-blocked-by a[href='/issues/REL-8'] .text-slate-500", "Was blocking")
      assert has_element?(view, "#issue-blocks a[href='/issues/REL-7']", "Waiting")
    end

    test "a sub-issue links its parent and shows no empty sections", %{conn: conn, parent: parent, open_child: open_child} do
      # Linear failing on blockers leaves their sections out and nothing else.
      stub(Issues, :get_blockers, fn _issues -> raise "Linear is down" end)

      {:ok, view, _html} = live(conn, ~p"/issues/#{open_child.identifier}")
      render_async(view)

      assert has_element?(view, "#issue-parent-link[title='Title REL-1'][href='/issues/#{parent.identifier}']", "REL-1")
      assert has_element?(view, "#issue-status .text-emerald-500")
      refute has_element?(view, "#issue-sub-issues")
      refute has_element?(view, "#issue-blocked-by")
      refute has_element?(view, "#issue-blocks")
    end

    test "a sub-issue changing or a new one arriving from Linear updates the parent's open page", %{
      conn: conn,
      parent: parent,
      open_child: open_child,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, ~p"/issues/#{parent.identifier}")
      render_async(view)
      assert has_element?(view, "#issue-sub-issues", "1/2")

      webhook = fn action, external_id, identifier, state, extra ->
        %{
          "type" => "Issue",
          "action" => action,
          "data" =>
            Map.merge(
              %{
                "id" => external_id,
                "teamId" => "lin_team_id",
                "identifier" => identifier,
                "title" => "Title #{identifier}",
                "state" => state
              },
              extra
            )
        }
      end

      assert {:ok, _issue} =
               Issues.handle_linear_webhook(
                 workspace,
                 webhook.("update", open_child.external_id, "REL-3", %{"name" => "Done", "type" => "completed"}, %{})
               )

      assert has_element?(view, "#issue-sub-issues", "2/2")

      assert {:ok, _issue} =
               Issues.handle_linear_webhook(
                 workspace,
                 webhook.("create", "lin_REL-4", "REL-4", %{"name" => "Todo", "type" => "unstarted"}, %{
                   "parentId" => parent.external_id
                 })
               )

      assert has_element?(view, "#issue-sub-issues", "2/3")
      assert has_element?(view, "#issue-sub-issues a[href='/issues/REL-4']")
    end

    test "a blocker finishing through the webhook reads blockers again", %{
      conn: conn,
      parent: parent,
      insert: insert,
      workspace: workspace
    } do
      blocker = insert.("REL-5", %{})
      test_pid = self()

      stub(Issues, :get_blockers, fn [issue] ->
        send(test_pid, :blockers_read)
        %{issue.external_id => %{blocked_by: [%{issue: Repo.get!(Issue, blocker.id), in_project: true}], blocks: []}}
      end)

      {:ok, view, _html} = live(conn, ~p"/issues/#{parent.identifier}")
      render_async(view)
      assert_received :blockers_read
      assert has_element?(view, "#issue-blocked-by h2", "1")

      assert {:ok, _issue} =
               Issues.handle_linear_webhook(workspace, %{
                 "type" => "Issue",
                 "action" => "update",
                 "data" => %{
                   "id" => blocker.external_id,
                   "teamId" => "lin_team_id",
                   "identifier" => "REL-5",
                   "title" => "Title REL-5",
                   "state" => %{"name" => "Done", "type" => "completed"}
                 }
               })

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
end
