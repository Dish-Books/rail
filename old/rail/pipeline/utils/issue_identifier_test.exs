defmodule Rail.Pipeline.Utils.IssueIdentifierTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.IssueIdentifier

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(scope, %{
        name: "Issue Identifier Workspace",
        external_id: "lin_ws_issue_identifier",
        token: "lin_api_token_issue_identifier",
        webhook_secret: "whsec_issue_identifier"
      })

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Issue Identifier Project 13511",
        github_repo: "org/issue-identifier-13511",
        github_installation_id: 13_511,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_issue_identifier_13511",
        linear_team_key: "P13511",
        default_branch: "main",
        clone_path: "/tmp/repos/issue-identifier-13511"
      })

    %{project: project}
  end

  test "issue_identifier reads the identifier from a preloaded or un-preloaded issue", %{project: project} do
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_scratch_13504",
      "identifier" => "ENG-101",
      "title" => "Scratch Issue 13504"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Scratch Issue 13504"})
    {:ok, task} = Pipeline.create_task(issue, :product)

    assert issue_identifier(task) == "ENG-101"
    assert task |> Repo.preload(:issue) |> issue_identifier() == "ENG-101"
  end

  test "issue_identifier is nil without an issue" do
    assert is_nil(issue_identifier(%Task{issue_id: nil}))
    assert is_nil(issue_identifier(%Task{issue_id: "iss_nonexistent"}))
    assert is_nil(issue_identifier(nil))
  end
end
