defmodule Rail.Issues.Actions.SyncIssuesTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Workers.LinearSync
  alias Rail.Projects

  test "sync_issues/1 queues a pull of the project's issues instead of doing it inline" do
    {:ok, %{id: project_id} = project} =
      Projects.create_project(system_scope(), %{
        name: "Sync Issues Project",
        github_repo: "org/sync-issues",
        github_installation_id: 5501,
        key: "SYN",
        default_branch: "main",
        clone_path: "/tmp/repos/sync-issues"
      })

    asked_at = DateTime.utc_now()

    # No Linear stub is queued, so a request made here would raise.
    assert {:ok, %Oban.Job{}} = Issues.sync_issues(project)

    # The pages share the time the sync was asked for, which the last one prunes against.
    assert [%Oban.Job{args: %{"project_id" => ^project_id, "started_at" => started_at}}] =
             all_enqueued(worker: LinearSync)

    assert {:ok, started_at, 0} = DateTime.from_iso8601(started_at)
    assert DateTime.compare(started_at, asked_at) != :lt
  end
end
