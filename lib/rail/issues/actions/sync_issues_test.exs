defmodule Rail.Issues.Actions.SyncIssuesTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock

  test "sync_issues/2 syncs new issues and maps state types" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    %Project{id: project_id} =
      project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id, linear_team_id: "team_sync_1"})

    nodes = [
      %{
        "id" => "lin_sync_1",
        "identifier" => "ENG-101",
        "title" => "Sync 1",
        "description" => "Desc 1",
        "state" => %{"id" => "st_1", "name" => "Triage", "type" => "triage"},
        "branchName" => "branch-1",
        "url" => "https://linear.app/issue/ENG-101",
        "createdAt" => "2026-09-01T10:00:00.000Z",
        "updatedAt" => "2026-09-01T11:00:00.000Z"
      },
      %{
        "id" => "lin_sync_2",
        "identifier" => "ENG-102",
        "title" => "Sync 2",
        "description" => "Desc 2",
        "state" => %{"id" => "st_2", "name" => "In Progress", "type" => "started"},
        "branchName" => "branch-2",
        "url" => "https://linear.app/issue/ENG-102",
        "createdAt" => "2026-09-01T10:00:00.000Z",
        "updatedAt" => "2026-09-01T11:00:00.000Z"
      },
      %{
        "id" => "lin_sync_3",
        "identifier" => "ENG-103",
        "title" => "Sync 3",
        "description" => "Desc 3",
        "state" => %{"id" => "st_3", "name" => "Done", "type" => "completed"},
        "branchName" => "branch-3",
        "url" => "https://linear.app/issue/ENG-103",
        "createdAt" => "2026-09-01T10:00:00.000Z",
        "updatedAt" => "2026-09-01T11:00:00.000Z"
      },
      %{
        "id" => "lin_sync_4",
        "identifier" => "ENG-104",
        "title" => "Sync 4",
        "description" => "Desc 4",
        "state" => %{"id" => "st_4", "name" => "Canceled", "type" => "canceled"},
        "branchName" => nil,
        "url" => "https://linear.app/issue/ENG-104",
        "createdAt" => "2026-09-01T10:00:00.000Z",
        "updatedAt" => "2026-09-01T11:00:00.000Z"
      },
      %{
        "id" => "lin_sync_5",
        "identifier" => "ENG-105",
        "title" => "Sync 5",
        "description" => "Desc 5",
        "state" => %{"id" => "st_5", "name" => "Backlog", "type" => "backlog"},
        "branchName" => nil,
        "url" => "https://linear.app/issue/ENG-105",
        "createdAt" => "2026-09-01T10:00:00.000Z",
        "updatedAt" => "2026-09-01T11:00:00.000Z"
      },
      %{
        "id" => "lin_sync_6",
        "identifier" => "ENG-106",
        "title" => "Sync 6",
        "description" => "Desc 6",
        "state" => %{"id" => "st_6", "name" => "Unstarted", "type" => "unstarted"},
        "branchName" => nil,
        "url" => "https://linear.app/issue/ENG-106",
        "createdAt" => "2026-09-01T10:00:00.000Z",
        "updatedAt" => "2026-09-01T11:00:00.000Z"
      },
      %{
        "id" => "lin_sync_7",
        "identifier" => "ENG-107",
        "title" => "Sync 7",
        "description" => "Desc 7",
        "state" => %{"id" => "st_7", "name" => "Custom", "type" => "unknown_type"},
        "branchName" => nil,
        "url" => "https://linear.app/issue/ENG-107",
        "createdAt" => nil,
        "updatedAt" => "invalid-iso"
      }
    ]

    LinearMock.mock_issues_success(nodes)

    scope = Scope.for_system()

    assert {:ok, synced} = Issues.sync_issues(scope, project)
    assert length(synced) == 7

    assert %Issue{project_id: ^project_id, state: :triage, state_name: "Triage"} =
             Repo.get_by(Issue, external_id: "lin_sync_1")

    assert %Issue{project_id: ^project_id, state: :in_progress, state_name: "In Progress"} =
             Repo.get_by(Issue, external_id: "lin_sync_2")

    assert %Issue{project_id: ^project_id, state: :done, state_name: "Done"} =
             Repo.get_by(Issue, external_id: "lin_sync_3")

    assert %Issue{project_id: ^project_id, state: :canceled} =
             Repo.get_by(Issue, external_id: "lin_sync_4")

    assert %Issue{project_id: ^project_id, state: :backlog} =
             Repo.get_by(Issue, external_id: "lin_sync_5")

    assert %Issue{project_id: ^project_id, state: :backlog} =
             Repo.get_by(Issue, external_id: "lin_sync_6")

    assert %Issue{project_id: ^project_id, state: :backlog} =
             Repo.get_by(Issue, external_id: "lin_sync_7")
  end

  test "sync_issues/2 updates existing issues when already present" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id, linear_team_id: "team_sync_2"})

    %Issue{id: existing_id} =
      Repo.insert!(%{
        Issue.factory()
        | project_id: project.id,
          external_id: "lin_exist_1",
          identifier: "ENG-200",
          title: "Old Title",
          state: :triage,
          linear_updated_at: ~U[2026-09-01 10:00:00.000000Z]
      })

    updated_node = %{
      "id" => "lin_exist_1",
      "identifier" => "ENG-200",
      "title" => "Updated Title",
      "description" => "New Desc",
      "state" => %{"id" => "st_2", "name" => "In Progress", "type" => "started"},
      "branchName" => "eng-200-branch",
      "url" => "https://linear.app/issue/ENG-200",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-02T10:00:00.000Z"
    }

    LinearMock.mock_issues_success([updated_node])

    scope = Scope.for_user(%{admin: false})

    assert {:ok, [%Issue{id: ^existing_id, title: "Updated Title", state: :in_progress}]} =
             Issues.sync_issues(scope, project)
  end

  test "sync_issues/2 returns error on API failure" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id, linear_team_id: "team_sync_3"})

    LinearMock.mock_api_error(500, %{"error" => "Linear Server Down"})

    scope = Scope.for_system()

    assert {:error, {:linear_api_error, 500, %{"error" => "Linear Server Down"}}} =
             Issues.sync_issues(scope, project)
  end

  test "sync_issues/2 returns :not_authorized for invalid scope" do
    project = Repo.insert!(Project.factory())

    assert {:error, :not_authorized} = Issues.sync_issues(nil, project)
    assert {:error, :not_authorized} = Issues.sync_issues(%Scope{user: nil}, project)
  end
end
