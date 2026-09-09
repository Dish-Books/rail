defmodule Rail.Issues.Actions.ArchiveIssueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User
  alias RailTest.Mocks.Linear, as: LinearMock

  test "archive_issue/2 cancels issue in Linear and updates local issue" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    project =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          linear_team_id: "team_arc_1",
          linear_state_ids: %{"canceled" => "st_canceled_1"}
      })

    issue =
      Repo.insert!(%{
        Issue.factory()
        | project_id: project.id,
          external_id: "lin_arc_1",
          identifier: "ENG-701",
          state: :in_progress,
          state_name: "In Progress"
      })

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_arc_1",
      "identifier" => "ENG-701",
      "title" => issue.title,
      "description" => issue.description,
      "state" => %{"id" => "st_canceled_1", "name" => "Canceled", "type" => "canceled"},
      "branchName" => nil,
      "url" => issue.url,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-02T12:00:00.000Z"
    })

    scope = Scope.for_system()

    assert {:ok, %Issue{state: :canceled, state_name: "Canceled"}} =
             Issues.archive_issue(scope, issue)
  end

  test "archive_issue/2 works with user scope and atom keyed linear_state_ids" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    project =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          linear_team_id: "team_arc_user",
          linear_state_ids: %{canceled: "st_canceled_atom"}
      })

    issue =
      Repo.insert!(%{
        Issue.factory()
        | project_id: project.id,
          external_id: "lin_arc_user",
          identifier: "ENG-702",
          state: :in_progress,
          state_name: "In Progress"
      })

    user =
      Repo.insert!(%{
        User.factory()
        | linear_access_token: "lin_arc_user_token",
          linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
      })

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_arc_user",
      "identifier" => "ENG-702",
      "title" => issue.title,
      "description" => issue.description,
      "state" => %{"id" => "st_canceled_atom", "name" => "Canceled", "type" => "canceled"},
      "branchName" => nil,
      "url" => issue.url,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-02T12:00:00.000Z"
    })

    scope = Scope.for_user(user)

    assert {:ok, %Issue{state: :canceled, state_name: "Canceled"}} =
             Issues.archive_issue(scope, issue)
  end

  test "archive_issue/2 returns error on Linear mutation failure" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id, linear_state_ids: nil})
    issue = Repo.insert!(%{Issue.factory() | project_id: project.id, external_id: "lin_arc_2"})

    LinearMock.mock_mutation_failure("issueUpdate")
    scope = Scope.for_system()

    assert {:error, {:linear_mutation_failed, "issueUpdate"}} =
             Issues.archive_issue(scope, issue)
  end

  test "archive_issue/2 returns :not_authorized for nil scope" do
    issue = %Issue{project_id: "prj_1", external_id: "lin_1"}
    assert {:error, :not_authorized} = Issues.archive_issue(nil, issue)
  end
end
