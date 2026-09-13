defmodule Rail.Issues.Actions.MoveStateTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Users
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Move State Workspace",
        external_id: "lin_ws_move_state",
        token: "lin_api_token_move_state",
        webhook_secret: "whsec_move_state"
      })

    %{workspace: workspace}
  end

  test "move_state/5 moves state using cached state ids", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Move State Cached",
        github_repo: "org/move-state-cached",
        github_installation_id: 6001,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_move_state_cached",
        linear_team_key: "MV1",
        default_branch: "main",
        clone_path: "/tmp/repos/move-state-cached",
        linear_state_ids: %{"done" => "st_done_cached"}
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_move_1",
      "identifier" => "ENG-1001",
      "title" => "Cached Move Issue",
      "description" => "Cached Move Issue",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-1001",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Cached Move Issue"})

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_move_1",
      "identifier" => "ENG-1001",
      "title" => issue.title,
      "description" => issue.description,
      "state" => %{"id" => "st_done_cached", "name" => "Done", "type" => "completed"},
      "branchName" => nil,
      "url" => issue.url,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-04T10:00:00.000Z"
    })

    assert {:ok, %Issue{state: :done, state_name: "Done"}} =
             Issues.move_state(project, issue, :done)
  end

  test "move_state/5 resolves state from Linear when not cached for triage, backlog, done, in_progress, and fallback", %{
    workspace: workspace
  } do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Move State Fetched",
        github_repo: "org/move-state-fetched",
        github_installation_id: 6002,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_move_state_fetched",
        linear_team_key: "MV2",
        default_branch: "main",
        clone_path: "/tmp/repos/move-state-fetched",
        linear_state_ids: %{}
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_move_2",
      "identifier" => "ENG-1002",
      "title" => "Fetched Move Issue",
      "description" => "Fetched Move Issue",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-1002",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Fetched Move Issue"})

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_move_state_user",
        login: "move_state_user",
        email: "move_state_user@example.com"
      })

    Users.update_user(Scope.for_system(), user, %{
      linear_access_token: "lin_move_user_tok",
      linear_refresh_token: "lin_move_user_refresh",
      linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
    })

    # 1. :triage with invalid datetime
    LinearMock.mock_workflow_states_success([
      %{"id" => "st_tri_fetched", "name" => "Triage", "type" => "triage"}
    ])

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_move_2",
      "identifier" => "ENG-1002",
      "title" => issue.title,
      "description" => issue.description,
      "state" => %{"id" => "st_tri_fetched", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => issue.url,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "invalid-iso"
    })

    assert {:ok, %Issue{state: :triage}} =
             Issues.move_state(project, issue, :triage)

    # 2. :backlog
    LinearMock.mock_workflow_states_success([
      %{"id" => "st_back_fetched", "name" => "Backlog", "type" => "backlog"}
    ])

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_move_2",
      "identifier" => "ENG-1002",
      "title" => issue.title,
      "description" => issue.description,
      "state" => %{"id" => "st_back_fetched", "name" => "Backlog", "type" => "backlog"},
      "branchName" => nil,
      "url" => issue.url,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-04T10:00:00.000Z"
    })

    assert {:ok, %Issue{state: :backlog}} =
             Issues.move_state(project, issue, :backlog)

    # 3. :done with nil updatedAt
    LinearMock.mock_workflow_states_success([
      %{"id" => "st_done_fetched", "name" => "Done", "type" => "completed"}
    ])

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_move_2",
      "identifier" => "ENG-1002",
      "title" => issue.title,
      "description" => issue.description,
      "state" => %{"id" => "st_done_fetched", "name" => "Done", "type" => "completed"},
      "branchName" => nil,
      "url" => issue.url,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => nil
    })

    assert {:ok, %Issue{state: :done}} =
             Issues.move_state(project, issue, :done)

    # 4. :in_progress
    LinearMock.mock_workflow_states_success([
      %{"id" => "st_started_fetched", "name" => "In Progress", "type" => "started"}
    ])

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_move_2",
      "identifier" => "ENG-1002",
      "title" => issue.title,
      "description" => issue.description,
      "state" => %{"id" => "st_started_fetched", "name" => "In Progress", "type" => "started"},
      "branchName" => nil,
      "url" => issue.url,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-04T10:00:00.000Z"
    })

    assert {:ok, %Issue{state: :in_progress}} =
             Issues.move_state(project, issue, :in_progress)

    # 5. :custom fallback (tests linear_type_for_state(_other) returning state_not_found)
    LinearMock.mock_workflow_states_success([
      %{"id" => "st_other", "name" => "Other", "type" => "other"}
    ])

    assert {:error, {:state_not_found, :custom}} =
             Issues.move_state(project, issue, :custom)
  end

  test "move_state/5 returns error when Linear update_issue mutation fails", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Move State Mutation Error",
        github_repo: "org/move-state-mut-err",
        github_installation_id: 6003,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_move_state_mut_err",
        linear_team_key: "MV3",
        default_branch: "main",
        clone_path: "/tmp/repos/move-state-mut-err",
        linear_state_ids: %{"done" => "st_done"}
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_move_err",
      "identifier" => "ENG-1003",
      "title" => "Mutation Error Issue",
      "description" => "Mutation Error Issue",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-1003",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Mutation Error Issue"})

    LinearMock.mock_mutation_failure("issueUpdate")

    assert {:error, {:linear_mutation_failed, "issueUpdate"}} =
             Issues.move_state(project, issue, :done)
  end

  test "move_state/5 returns error when Linear workflow_states fails", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Move State Workflow Error",
        github_repo: "org/move-state-ws-err",
        github_installation_id: 6004,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_move_state_ws_err",
        linear_team_key: "MV4",
        default_branch: "main",
        clone_path: "/tmp/repos/move-state-ws-err",
        linear_state_ids: %{}
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_move_ws_err",
      "identifier" => "ENG-1004",
      "title" => "Workflow Error Issue",
      "description" => "Workflow Error Issue",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-1004",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Workflow Error Issue"})

    LinearMock.mock_graphql_error([%{"message" => "Workflow states error"}])

    assert {:error, {:linear_graphql_error, _errors}} =
             Issues.move_state(project, issue, :done)
  end

  test "move_state/5 returns error when state cannot be resolved from Linear", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Move State Unresolved",
        github_repo: "org/move-state-unresolved",
        github_installation_id: 6005,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_move_state_unresolved",
        linear_team_key: "MV5",
        default_branch: "main",
        clone_path: "/tmp/repos/move-state-unresolved",
        linear_state_ids: %{}
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_move_3",
      "identifier" => "ENG-1005",
      "title" => "Unresolved Move Issue",
      "description" => "Unresolved Move Issue",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-1005",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Unresolved Move Issue"})

    LinearMock.mock_workflow_states_success([])

    assert {:error, {:state_not_found, :canceled}} =
             Issues.move_state(project, issue, :canceled)
  end
end
