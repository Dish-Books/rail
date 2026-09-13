defmodule Rail.Issues.Actions.SyncIssuesTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Workers.SyncProjectIssues
  alias Rail.Projects

  test "sync_issues/1 queues a pull of the project's issues instead of doing it inline" do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Sync Issues Project",
        github_repo: "org/sync-issues",
        github_installation_id: 5501,
        linear_workspace: %{
          name: "Sync Issues Workspace",
          external_id: "lin_ws_sync_issues",
          token: "lin_api_token_sync_issues",
          webhook_secret: "whsec_sync_issues"
        },
        linear_team_key: "SYN",
        default_branch: "main",
        clone_path: "/tmp/repos/sync-issues"
      })

    # No Linear stub is queued, so a request made here would raise.
    assert {:ok, %Oban.Job{}} = Issues.sync_issues(project)

    assert_enqueued(worker: SyncProjectIssues, args: %{project_id: project.id})
  end
end
