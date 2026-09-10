defmodule Rail.IssuesTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock

  test "top-level Rail.Issues delegates read and write functions" do
    scope = Scope.for_system()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(scope, %{
        name: "Issues Context Workspace",
        external_id: "lin_ws_issues_context",
        token: "lin_api_token_issues_context",
        webhook_secret: "whsec_issues_context"
      })

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Issues Context Project",
        github_repo: "org/issues-context",
        github_installation_id: 5601,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_issues_context",
        linear_team_key: "ICT",
        clone_path: "/tmp/repos/issues-context"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_top_1",
      "identifier" => "ENG-1111",
      "title" => "Top Issue",
      "description" => "Top Issue",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "branchName" => "eng-1111-top",
      "url" => "https://linear.app/issue/ENG-1111",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Top Issue")

    assert {:ok, %Issue{identifier: "ENG-1111"}} = Issues.get_issue(scope, issue.id)
    assert [%Issue{identifier: "ENG-1111"}] = Issues.list_issues(scope, project)
  end
end
