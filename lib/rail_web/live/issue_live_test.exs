defmodule RailWeb.IssueLiveTest do
  use RailWeb.ConnCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Phoenix.LiveViewTest

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  setup %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issue_live",
        login: "issue_live_user",
        name: "Issue Live",
        email: "issue_live_user@example.com"
      })

    %{conn: log_in_user(conn, user), user: user, project: project}
  end

  test "shows the issue's title, description and properties", %{conn: conn, user: user, project: project} do
    issue =
      %Issue{}
      |> Issue.linear_changeset(%{
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
    assert has_element?(view, "#issue-linear-link[href='https://linear.app/issue/IPG-7']")
    assert has_element?(view, "#issue-branch[phx-hook='CopyText'][data-copy-text='ipg-7-ap-aging']")
  end

  test "the assignee can be changed to a Linear-linked user, or cleared", %{conn: conn, user: user, project: project} do
    {:ok, %{id: teammate_id} = teammate} =
      Users.register_oauth_user(%{
        github_id: "gh_issue_teammate",
        login: "teammate",
        name: "Paulo Teammate",
        email: "teammate@example.com"
      })

    teammate |> Ecto.Changeset.change(linear_user_id: "lin_usr_teammate") |> Repo.update!()

    issue =
      %Issue{}
      |> Issue.linear_changeset(%{
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

    view |> element("#issue-owner-search-form") |> render_change(%{"q" => "nobody"})
    refute has_element?(view, "#issue-assign-#{teammate.id}")

    view |> element("#issue-owner-search-form") |> render_change(%{"q" => "paulo"})
    view |> element("#issue-assign-#{teammate.id}") |> render_click()

    assert has_element?(view, "#issue-owner", "Paulo Teammate")
    assert %Issue{owner_user_id: ^teammate_id} = Repo.get!(Issue, issue.id)
    assert_enqueued(worker: SyncIssue, args: %{issue_id: issue.id, fields: ["owner_user_id"]})

    view |> element("#issue-assign-none") |> render_click()

    assert has_element?(view, "#issue-owner", "Unassigned")
    assert %Issue{owner_user_id: nil} = Repo.get!(Issue, issue.id)
  end

  test "an issue with no task can be started from its page", %{conn: conn, project: project} do
    issue =
      %Issue{}
      |> Issue.linear_changeset(%{
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

    view |> element("#issue-start-product") |> render_click()

    assert %Task{id: task_id, stage: :product} = Repo.get_by(Task, issue_id: issue.id)
    assert_redirect(view, ~p"/tasks/#{task_id}")
  end

  test "an issue whose ticket is written can start at design, skipping product", %{conn: conn, project: project} do
    issue =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_page_17",
        identifier: "IPG-17",
        title: "Already written",
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

    view |> element("#issue-start-design") |> render_click()

    assert %Task{id: task_id, stage: :design} = Repo.get_by(Task, issue_id: issue.id)
    assert_redirect(view, ~p"/tasks/#{task_id}")
  end

  test "an issue that cannot be started says why and keeps no task", %{conn: conn, project: project} do
    issue =
      %Issue{}
      |> Issue.linear_changeset(%{
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

    view |> element("#issue-start-product") |> render_click()

    assert has_element?(view, "#flash-error", "Could not create the worktree: no checkout")
    assert has_element?(view, "#issue-start-product")
    refute has_element?(view, "#issue-task-link")
    refute Repo.get_by(Task, issue_id: issue.id)
  end

  test "shows comment threads with their replies, and refreshes when a comment arrives", %{
    conn: conn,
    project: project
  } do
    issue =
      %Issue{}
      |> Issue.linear_changeset(%{
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
      |> Issue.linear_changeset(%{
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
        |> Issue.linear_changeset(%{
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

    view |> element("#issue-start-product") |> render_click()
    assert has_element?(view, "#flash-error", "Could not create the worktree: no checkout")

    view |> element("#issue-start-product") |> render_click()
    assert has_element?(view, "#flash-error", "Could not start the agent: :enoent")

    assert {:ok, dispatch_view, _html} = live(conn, ~p"/issues/#{dispatch_issue.identifier}")
    allow(Git, self(), dispatch_view.pid)
    allow(Tools, self(), dispatch_view.pid)

    dispatch_view |> element("#issue-start-product") |> render_click()
    assert has_element?(dispatch_view, "#flash-error", "Dispatch is switched off, so no agent was started.")

    assert {:ok, other_view, _html} = live(conn, ~p"/issues/#{other_issue.identifier}")
    allow(Git, self(), other_view.pid)
    allow(Tools, self(), other_view.pid)

    other_view |> element("#issue-start-product") |> render_click()
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

    teammate |> Ecto.Changeset.change(linear_user_id: "lin_usr_failing") |> Repo.update!()

    issue =
      %Issue{}
      |> Issue.linear_changeset(%{
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

    expect(Issues, :update_issue, fn issue, attrs -> {:error, Issue.linear_changeset(issue, attrs)} end)

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
      |> Issue.linear_changeset(%{
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

  test "an unknown issue goes back to the list", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/issues", flash: %{"error" => "Issue not found"}}}} =
             live(conn, ~p"/issues/iss_missing")
  end
end
