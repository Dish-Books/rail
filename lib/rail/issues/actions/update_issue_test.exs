defmodule Rail.Issues.Actions.UpdateIssueTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.AdvanceTrackerState
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Projects
  alias Rail.Users

  setup do
    key = "Upd#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Updated",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Issue", description: "Initial Title"})

    %{project: project, issue: issue}
  end

  test "writes the row", %{issue: issue} do
    assert {:ok, %Issue{title: "Updated Title", description: "Updated body"}} =
             Issues.update_issue(issue, %{title: "Updated Title", description: "Updated body"})

    assert %Issue{title: "Updated Title"} = Repo.get!(Issue, issue.id)
  end

  test "enqueues the sync naming only the issue", %{issue: %Issue{id: issue_id} = issue} do
    {:ok, _issue} = Issues.update_issue(issue, %{title: "Only the title"})

    assert [%Oban.Job{args: %{"issue_id" => ^issue_id} = args}] = all_enqueued(worker: SyncIssue)
    assert map_size(args) == 1
  end

  test "enqueues nothing when nothing changed", %{issue: issue} do
    {:ok, _issue} = Issues.update_issue(issue, %{title: issue.title})

    refute_enqueued(worker: SyncIssue)
  end

  test "giving an issue an owner, another or none queues no status move", %{issue: issue} do
    [first, second] =
      Enum.map(["first_owner", "second_owner"], fn login ->
        {:ok, user} =
          Users.register_oauth_user(%{
            github_id: "gh_#{login}_update-issue",
            login: "#{login}-update-issue",
            email: "#{login}-update-issue@example.com"
          })

        user
      end)

    {:ok, owned} = Issues.update_issue(issue, %{owner_user_id: first.id})
    {:ok, handed_on} = Issues.update_issue(owned, %{owner_user_id: second.id})
    {:ok, _unowned} = Issues.update_issue(handed_on, %{owner_user_id: nil})
    refute_enqueued(worker: AdvanceTrackerState)
  end
end
