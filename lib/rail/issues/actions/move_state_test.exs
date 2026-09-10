defmodule Rail.Issues.Actions.MoveStateTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User
  alias RailTest.Mocks.Linear, as: LinearMock

  test "move_state/5 moves state using cached state ids" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    project =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          linear_team_id: "team_move_1",
          linear_state_ids: %{"done" => "st_done_cached"}
      })

    issue =
      Repo.insert!(%{
        Issue.factory()
        | project_id: project.id,
          external_id: "lin_move_1",
          identifier: "ENG-1001",
          state: :in_progress
      })

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

    scope = Scope.for_system()

    assert {:ok, %Issue{state: :done, state_name: "Done"}} =
             Issues.move_state(scope, project, issue, :done)
  end

  test "move_state/5 resolves state from Linear when not cached for triage, backlog, done, in_progress, and fallback" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    project =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          linear_team_id: "team_move_2",
          linear_state_ids: %{}
      })

    issue =
      Repo.insert!(%{
        Issue.factory()
        | project_id: project.id,
          external_id: "lin_move_2",
          identifier: "ENG-1002",
          state: :triage
      })

    user =
      Repo.insert!(%{
        User.factory()
        | linear_access_token: "lin_move_user_tok",
          linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
      })

    scope = Scope.for_user(user)

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
             Issues.move_state(scope, project, issue, :triage)

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
             Issues.move_state(scope, project, issue, :backlog)

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
             Issues.move_state(scope, project, issue, :done)

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
             Issues.move_state(scope, project, issue, :in_progress)

    # 5. :custom fallback (tests linear_type_for_state(_other) returning state_not_found)
    LinearMock.mock_workflow_states_success([
      %{"id" => "st_other", "name" => "Other", "type" => "other"}
    ])

    assert {:error, {:state_not_found, :custom}} =
             Issues.move_state(scope, project, issue, :custom)
  end

  test "move_state/5 returns error when Linear update_issue mutation fails" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    project =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          linear_team_id: "team_move_err",
          linear_state_ids: %{"done" => "st_done"}
      })

    issue = Repo.insert!(%{Issue.factory() | project_id: project.id, external_id: "lin_move_err"})
    LinearMock.mock_mutation_failure("issueUpdate")
    scope = Scope.for_system()

    assert {:error, {:linear_mutation_failed, "issueUpdate"}} =
             Issues.move_state(scope, project, issue, :done)
  end

  test "move_state/5 returns error when Linear workflow_states fails" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    project =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          linear_team_id: "team_move_ws_err",
          linear_state_ids: %{}
      })

    issue = Repo.insert!(%{Issue.factory() | project_id: project.id, external_id: "lin_move_ws_err"})
    LinearMock.mock_graphql_error([%{"message" => "Workflow states error"}])
    scope = Scope.for_system()

    assert {:error, {:linear_graphql_error, _errors}} =
             Issues.move_state(scope, project, issue, :done)
  end

  test "move_state/5 returns error when state cannot be resolved from Linear" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    project =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          linear_team_id: "team_move_3",
          linear_state_ids: %{}
      })

    issue = Repo.insert!(%{Issue.factory() | project_id: project.id, external_id: "lin_move_3"})

    LinearMock.mock_workflow_states_success([])

    scope = Scope.for_system()

    assert {:error, {:state_not_found, :canceled}} =
             Issues.move_state(scope, project, issue, :canceled)
  end

  test "move_state/5 returns :not_authorized for nil scope" do
    project = Repo.insert!(Project.factory())
    issue = %Issue{project_id: project.id, external_id: "lin_1"}
    assert {:error, :not_authorized} = Issues.move_state(nil, project, issue, :done)
  end
end
