defmodule RailWeb.IssueLiveTest do
  use RailWeb.ConnCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Phoenix.LiveViewTest

  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Users

  setup %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_issue_live",
        login: "issue_live_user",
        name: "Issue Live",
        email: "issue_live_user@example.com"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Issue Page Project",
        github_repo: "org/issue-page",
        github_installation_id: 5301,
        linear_team_key: "IPG",
        default_branch: "main",
        clone_path: "/tmp/repos/issue-page"
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
    assert has_element?(view, "#issue-project", "Issue Page Project")
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

    assert {:ok, view, _html} = live(conn, ~p"/issues/#{issue.identifier}")

    assert has_element?(view, "#issue-description", "No description")
    assert has_element?(view, "#issue-owner", "Unassigned")
    refute has_element?(view, "#issue-task-link")

    view |> element("#issue-start-product-run") |> render_click()

    refute has_element?(view, "#issue-start-product-run")
    assert has_element?(view, "#issue-task-link")
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

  test "posting a comment and a reply sends them to Linear and shows them", %{conn: conn} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Issue Comment Project",
        github_repo: "org/issue-comment",
        github_installation_id: 5302,
        linear_team_key: "ICP",
        default_branch: "main",
        clone_path: "/tmp/repos/issue-comment",
        linear_workspace: %{
          name: "Issue Comment Workspace",
          external_id: "lin_ws_issue_comment",
          token: "lin_api_token_issue_comment",
          webhook_secret: "whsec_issue_comment"
        }
      })

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

  test "an unknown issue goes back to the list", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/issues", flash: %{"error" => "Issue not found"}}}} =
             live(conn, ~p"/issues/iss_missing")
  end
end
