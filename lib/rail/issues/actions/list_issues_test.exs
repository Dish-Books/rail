defmodule Rail.Issues.Actions.ListIssuesTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock

  test "list_issues lists issues for project with default show_finished: false" do
    scope = Scope.for_system()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(scope, %{
        name: "List Issues Workspace",
        external_id: "lin_ws_list_issues",
        token: "lin_api_token_list_issues",
        webhook_secret: "whsec_list_issues"
      })

    {:ok, %Project{id: project_id_1} = project_1} =
      Projects.create_project(scope, %{
        name: "List Issues Project One",
        github_repo: "org/list-issues-one",
        github_installation_id: 5701,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_list_issues_one",
        linear_team_key: "LI1",
        default_branch: "main",
        clone_path: "/tmp/repos/list-issues-one"
      })

    {:ok, %Project{id: project_id_2} = project_2} =
      Projects.create_project(scope, %{
        name: "List Issues Project Two",
        github_repo: "org/list-issues-two",
        github_installation_id: 5702,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_list_issues_two",
        linear_team_key: "LI2",
        default_branch: "main",
        clone_path: "/tmp/repos/list-issues-two"
      })

    LinearMock.mock_issues_success([
      %{
        "id" => "lin_list_1",
        "identifier" => "ENG-501",
        "title" => "Triage Issue",
        "description" => "Triage",
        "state" => %{"id" => "st_1", "name" => "Triage", "type" => "triage"},
        "branchName" => nil,
        "url" => "https://linear.app/issue/ENG-501",
        "createdAt" => "2026-09-01T10:00:00.000Z",
        "updatedAt" => "2026-09-01T10:00:00.000Z"
      },
      %{
        "id" => "lin_list_2",
        "identifier" => "ENG-502",
        "title" => "Done Issue",
        "description" => "Done",
        "state" => %{"id" => "st_2", "name" => "Done", "type" => "completed"},
        "branchName" => nil,
        "url" => "https://linear.app/issue/ENG-502",
        "createdAt" => "2026-09-01T10:00:00.000Z",
        "updatedAt" => "2026-09-01T10:01:00.000Z"
      }
    ])

    {:ok, [%Issue{id: id1}, %Issue{id: id2}]} = Issues.sync_issues(project_1)

    LinearMock.mock_issues_success([
      %{
        "id" => "lin_list_3",
        "identifier" => "ENG-503",
        "title" => "In Progress Issue",
        "description" => "In Progress",
        "state" => %{"id" => "st_3", "name" => "In Progress", "type" => "started"},
        "branchName" => nil,
        "url" => "https://linear.app/issue/ENG-503",
        "createdAt" => "2026-09-01T10:00:00.000Z",
        "updatedAt" => "2026-09-01T10:00:00.000Z"
      }
    ])

    {:ok, [_issue_3]} = Issues.sync_issues(project_2)

    # Default show_finished: false excludes done issue id2
    assert [%Issue{id: ^id1}] = Issues.list_issues(project_1)

    # Explicit show_finished: true includes done issue id2
    assert [%Issue{id: ^id1}, %Issue{id: ^id2}] =
             Issues.list_issues(project_id: project_id_1, show_finished: true)

    # 3-arity list_issues with project struct and opts
    assert [%Issue{id: ^id1}, %Issue{id: ^id2}] =
             Issues.list_issues(project_1, show_finished: true)

    assert [%Issue{id: ^id1}] = Issues.list_issues(project_id: project_id_1, state: :triage)

    # Preload option preloads associations
    assert [%Issue{id: ^id1, project: %Project{id: ^project_id_1}}] =
             Issues.list_issues(project_id: project_id_1, preload: [:project])

    assert project_id_2 != project_id_1
    assert length(Issues.list_issues(show_finished: true)) == 3
    assert length(Issues.list_issues(show_finished: false)) == 2
    assert length(Issues.list_issues()) == 2
  end
end
