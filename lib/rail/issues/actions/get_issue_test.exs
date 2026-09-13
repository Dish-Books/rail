defmodule Rail.Issues.Actions.GetIssueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(scope, %{
        name: "Get Issue Workspace",
        external_id: "lin_ws_get_issue",
        token: "lin_api_token_get_issue",
        webhook_secret: "whsec_get_issue"
      })

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Get Issue Project",
        github_repo: "org/get-issue",
        github_installation_id: 5101,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_get_issue",
        linear_team_key: "GTI",
        default_branch: "main",
        clone_path: "/tmp/repos/get-issue"
      })

    %{project: project, workspace: workspace}
  end

  test "get_issue/2 retrieves an existing issue by id and external_id", %{project: project} do
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_get_1",
      "identifier" => "ENG-401",
      "title" => "Get Issue Test",
      "description" => "Get Issue Test",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "branchName" => "eng-401-get-issue",
      "url" => "https://linear.app/issue/ENG-401",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    {:ok, %Issue{id: issue_id}} = Issues.create_issue(project, %{description: "Get Issue Test"})

    assert {:ok, %Issue{id: ^issue_id, title: "Get Issue Test"}} =
             Issues.get_issue(issue_id)

    assert {:ok, %Issue{id: ^issue_id, title: "Get Issue Test"}} =
             Issues.get_issue("lin_get_1")
  end

  test "get_issue/2 returns {:error, :not_found} when issue does not exist" do
    assert {:error, :not_found} = Issues.get_issue("iss_nonexistent")
  end

  test "get_issue!/1 retrieves the issue or raises", %{project: project} do
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_get_2",
      "identifier" => "ENG-402",
      "title" => "Get Issue Bang",
      "description" => "Get Issue Bang",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "branchName" => "eng-402-get-issue",
      "url" => "https://linear.app/issue/ENG-402",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    {:ok, %Issue{id: issue_id}} = Issues.create_issue(project, %{description: "Get Issue Bang"})

    assert %Issue{id: ^issue_id} = Issues.get_issue!(issue_id)

    assert_raise Ecto.NoResultsError, fn ->
      Issues.get_issue!("iss_missing_123")
    end
  end
end
