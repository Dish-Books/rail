defmodule Rail.Issues.Workers.SyncIssueTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Users

  setup do
    key = "Syn#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Synced",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Kept in Rail"})
    %{issue: issue}
  end

  test "a new owner is told to open pages, with no request made", %{issue: %{id: issue_id} = issue} do
    {:ok, %{id: user_id}} =
      Users.register_oauth_user(%{github_id: "gh_local_sync", login: "local-sync", email: "ls@example.com"})

    {:ok, %Issue{owner_user_id: ^user_id}} = Issues.update_issue(issue, %{owner_user_id: user_id})
    [%Oban.Job{args: args}] = all_enqueued(worker: SyncIssue, args: %{issue_id: issue_id})
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    # The default Req adapter raises on any request, so none is made.
    assert :ok = perform_job(SyncIssue, args)
    assert_receive {:issue_changed, ^issue_id}
  end

  test "an issue that is gone needs no sync", %{issue: issue} do
    Repo.delete!(issue)

    assert :ok = perform_job(SyncIssue, %{issue_id: issue.id})
  end
end
