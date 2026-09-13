defmodule RailWeb.IssueLiveTest do
  use RailWeb.ConnCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Phoenix.LiveViewTest

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

  test "an unknown issue goes back to the list", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/issues", flash: %{"error" => "Issue not found"}}}} =
             live(conn, ~p"/issues/iss_missing")
  end
end
