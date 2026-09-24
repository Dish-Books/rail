defmodule Rail.Issues.Actions.SyncIssuesTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Workers.LinearSync
  alias Rail.Projects

  test "sync_issues/1 queues a pull of the project's issues instead of doing it inline" do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Sync Issues Project",
        github_repo: "org/sync-issues",
        github_installation_id: 5501,
        linear_team_key: "SYN",
        default_branch: "main",
        clone_path: "/tmp/repos/sync-issues"
      })

    # No Linear stub is queued, so a request made here would raise.
    assert {:ok, %Oban.Job{}} = Issues.sync_issues(project)

    assert_enqueued(worker: LinearSync, args: %{project_id: project.id})
  end
end
