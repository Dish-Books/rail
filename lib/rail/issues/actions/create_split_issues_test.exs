defmodule Rail.Issues.Actions.CreateSplitIssuesTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.TicketBody
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Users
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Split Issues Workspace",
        external_id: "lin_ws_split_issues",
        token: "lin_api_token_split_issues",
        webhook_secret: "whsec_split_issues"
      })

    %{workspace: workspace}
  end

  test "create_split_issues/4 creates multiple split tickets in Linear and mirrors locally", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Split Issues Project 6201",
        github_repo: "org/split-issues-6201",
        github_installation_id: 6201,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_split_1",
        linear_team_key: "SP1",
        clone_path: "/tmp/repos/split-issues-6201",
        linear_state_ids: %{"triage" => "st_triage_split"}
      })

    {:ok, owner} =
      Users.register_oauth_user(%{
        github_id: "gh_split_issues_6202",
        login: "split_issues_user_6202",
        email: "split_issues_user_6202@example.com"
      })

    {:ok, owner} =
      Users.link_linear(owner, %{
        access_token: "lin_split_owner_tok",
        refresh_token: "lin_refresh_6202",
        expires_in: 3600
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_split_1",
      "identifier" => "ENG-901",
      "title" => "Split Ticket 1",
      "description" => "Description 1",
      "state" => %{"id" => "st_triage_split", "name" => "Triage", "type" => "triage"},
      "branchName" => "eng-901-branch",
      "url" => "https://linear.app/issue/ENG-901",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_split_2",
      "identifier" => "ENG-902",
      "title" => "Split Ticket 2",
      "description" => "Description 2",
      "state" => %{"id" => "st_triage_split", "name" => "Triage", "type" => "triage"},
      "branchName" => "eng-902-branch",
      "url" => "https://linear.app/issue/ENG-902",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_split_3",
      "identifier" => "ENG-903",
      "title" => "Atom Title",
      "description" => "Atom Desc",
      "state" => %{"id" => "st_triage_split", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-903",
      "createdAt" => nil,
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_split_4",
      "identifier" => "ENG-904",
      "title" => "String Title",
      "description" => "String Desc",
      "state" => %{"id" => "st_triage_split", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-904",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "invalid-iso"
    })

    splits = [
      %TicketBody{title: "Split Ticket 1", description: "Description 1"},
      %{"title" => "Split Ticket 2", "description" => "Description 2"},
      %{title: "Atom Title", description: "Atom Desc"},
      "# String Title\n\nString Desc"
    ]

    scope = Scope.for_user(owner)

    assert {:ok,
            [
              %Issue{external_id: "lin_split_1", identifier: "ENG-901", state: :triage},
              %Issue{external_id: "lin_split_2", identifier: "ENG-902", state: :triage},
              %Issue{external_id: "lin_split_3", identifier: "ENG-903", state: :triage},
              %Issue{external_id: "lin_split_4", identifier: "ENG-904", state: :triage}
            ]} = Issues.create_split_issues(scope, project, splits, owner)
  end

  test "create_split_issues/3 supports map of split files", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Split Issues Project 6203",
        github_repo: "org/split-issues-6203",
        github_installation_id: 6203,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_split_2",
        linear_team_key: "SP3",
        clone_path: "/tmp/repos/split-issues-6203",
        linear_state_ids: %{"triage" => "st_triage_split"}
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_split_5",
      "identifier" => "ENG-905",
      "title" => "Map Split",
      "description" => "Body",
      "state" => %{"id" => "st_triage_split", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-905",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    split_map = %{"split-1.md" => "# Map Split\n\nBody"}
    scope = Scope.for_system()

    assert {:ok, [%Issue{external_id: "lin_split_5"}]} =
             Issues.create_split_issues(scope, project, split_map)
  end

  test "create_split_issues/4 rolls back on Linear creation failure", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Split Issues Project 6204",
        github_repo: "org/split-issues-6204",
        github_installation_id: 6204,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_split_issues_6204",
        linear_team_key: "SP4",
        clone_path: "/tmp/repos/split-issues-6204"
      })

    LinearMock.mock_mutation_failure("issueCreate")
    scope = Scope.for_system()

    assert {:error, {:linear_mutation_failed, "issueCreate"}} =
             Issues.create_split_issues(scope, project, [%TicketBody{title: "Failing"}])
  end

  test "create_split_issues/3 returns :not_authorized for nil scope", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Split Issues Project 6205",
        github_repo: "org/split-issues-6205",
        github_installation_id: 6205,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_split_issues_6205",
        linear_team_key: "SP5",
        clone_path: "/tmp/repos/split-issues-6205"
      })

    assert {:error, :not_authorized} = Issues.create_split_issues(nil, project, [])
  end
end
