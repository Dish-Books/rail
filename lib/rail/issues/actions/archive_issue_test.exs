defmodule Rail.Issues.Actions.ArchiveIssueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Users
  alias RailTest.Mocks.Linear, as: LinearMock

  test "archive_issue/2 cancels issue in Linear and updates local issue" do
    scope = Scope.for_system()

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Archive Project",
        github_repo: "org/archive",
        github_installation_id: 5801,
        linear_workspace: %{
          name: "Archive Issue Workspace",
          external_id: "lin_ws_archive",
          token: "lin_api_token_archive",
          webhook_secret: "whsec_archive"
        },
        linear_team_id: "team_arc_1",
        linear_team_key: "ARC",
        default_branch: "main",
        clone_path: "/tmp/repos/archive",
        linear_state_ids: %{"canceled" => "st_canceled_1"}
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_arc_1",
      "identifier" => "ENG-701",
      "title" => "Archivable Issue",
      "description" => "Archivable Issue",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-701",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Archivable Issue"})

    {:ok, issue} = Issues.update_issue(issue, %{state: :in_progress, state_name: "In Progress"})

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

    assert {:ok, %Issue{state: :canceled, state_name: "Canceled"}} =
             Issues.archive_issue(issue)
  end

  test "archive_issue/2 works with user scope and atom keyed linear_state_ids" do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Archive User Project",
        github_repo: "org/archive-user",
        github_installation_id: 5802,
        linear_workspace: %{
          name: "Archive Issue Workspace",
          external_id: "lin_ws_archive_2",
          token: "lin_api_token_archive",
          webhook_secret: "whsec_archive"
        },
        linear_team_id: "team_arc_user",
        linear_team_key: "ARU",
        default_branch: "main",
        clone_path: "/tmp/repos/archive-user",
        linear_state_ids: %{canceled: "st_canceled_atom"}
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_arc_user",
      "identifier" => "ENG-702",
      "title" => "User Archivable Issue",
      "description" => "User Archivable Issue",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-702",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "User Archivable Issue"})

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_archive_user",
        login: "archive_user",
        email: "archive_user@example.com"
      })

    Users.update_user(Scope.for_system(), user, %{
      linear_access_token: "lin_arc_user_token",
      linear_refresh_token: "lin_arc_user_refresh",
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

    assert {:ok, %Issue{state: :canceled, state_name: "Canceled"}} =
             Issues.archive_issue(issue)
  end

  test "archive_issue/2 returns error on Linear mutation failure" do
    scope = Scope.for_system()

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Archive Failure Project",
        github_repo: "org/archive-failure",
        github_installation_id: 5803,
        linear_workspace: %{
          name: "Archive Issue Workspace",
          external_id: "lin_ws_archive_3",
          token: "lin_api_token_archive",
          webhook_secret: "whsec_archive"
        },
        linear_team_id: "team_arc_2",
        linear_team_key: "ARF",
        default_branch: "main",
        clone_path: "/tmp/repos/archive-failure",
        linear_state_ids: %{"canceled" => "st_canceled_2"}
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_arc_2",
      "identifier" => "ENG-703",
      "title" => "Failing Archive Issue",
      "description" => "Failing Archive Issue",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-703",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Failing Archive Issue"})

    LinearMock.mock_mutation_failure("issueUpdate")

    assert {:error, {:linear_mutation_failed, "issueUpdate"}} =
             Issues.archive_issue(issue)
  end
end
