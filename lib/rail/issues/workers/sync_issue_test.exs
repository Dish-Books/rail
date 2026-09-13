defmodule Rail.Issues.Workers.SyncIssueTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Projects
  alias Rail.Repo
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Sync Issue Workspace",
        external_id: "lin_ws_sync_issue",
        token: "lin_api_token_sync_issue",
        webhook_secret: "whsec_sync_issue"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Sync Issue Project",
        github_repo: "org/sync-issue",
        github_installation_id: 5902,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_sync_issue",
        linear_team_key: "SYN",
        default_branch: "main",
        clone_path: "/tmp/repos/sync-issue",
        linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_prog"}
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_sync_1",
      "identifier" => "SYN-1",
      "title" => "Sync Issue",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"}
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Sync Issue"})

    %{project: project, issue: issue}
  end

  test "pushes only the fields the update changed", %{issue: issue} do
    {:ok, issue} = Issues.update_issue(issue, %{title: "New title", description: "New body"})

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_sync_1",
      "identifier" => "SYN-1",
      "title" => "New title"
    })

    assert :ok = perform_job(SyncIssue, %{issue_id: issue.id, fields: ["title"]})
  end

  test "sends Linear the workflow state id, not Rail's word for it", %{issue: issue} do
    {:ok, issue} = Issues.update_issue(issue, %{state: :in_progress})

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_sync_1",
      "identifier" => "SYN-1",
      "title" => "Sync Issue"
    })

    assert :ok = perform_job(SyncIssue, %{issue_id: issue.id, fields: ["state"]})
  end

  test "says nothing to Linear when no pushable field changed", %{issue: issue} do
    # No Linear mock is queued, so a request would raise.
    assert :ok = perform_job(SyncIssue, %{issue_id: issue.id, fields: ["url", "identifier"]})
  end

  test "an issue that is gone needs no sync", %{issue: issue} do
    Repo.delete!(issue)

    assert :ok = perform_job(SyncIssue, %{issue_id: issue.id, fields: ["title"]})
  end
end
