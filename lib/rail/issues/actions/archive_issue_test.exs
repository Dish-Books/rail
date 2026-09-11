defmodule Rail.Issues.Actions.ArchiveIssueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Users
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(scope, %{
        name: "Archive Issue Workspace",
        external_id: "lin_ws_archive",
        token: "lin_api_token_archive",
        webhook_secret: "whsec_archive"
      })

    %{workspace: workspace}
  end

  test "archive_issue/2 cancels issue in Linear and updates local issue", %{workspace: workspace} do
    scope = Scope.for_system()

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Archive Project",
        github_repo: "org/archive",
        github_installation_id: 5801,
        linear_workspace_id: workspace.id,
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

    {:ok, issue} = Issues.capture_issue(scope, project, "Archivable Issue")

    {:ok, issue} = Issues.update_issue(scope, issue, %{state: :in_progress, state_name: "In Progress"})

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
             Issues.archive_issue(scope, issue)
  end

  test "archive_issue/2 works with user scope and atom keyed linear_state_ids", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Archive User Project",
        github_repo: "org/archive-user",
        github_installation_id: 5802,
        linear_workspace_id: workspace.id,
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

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "User Archivable Issue")

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_archive_user",
        login: "archive_user",
        email: "archive_user@example.com"
      })

    {:ok, user} =
      Users.link_linear(user, %{
        access_token: "lin_arc_user_token",
        refresh_token: "lin_arc_user_refresh",
        expires_in: 3600
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

  test "archive_issue/2 returns error on Linear mutation failure", %{workspace: workspace} do
    scope = Scope.for_system()

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Archive Failure Project",
        github_repo: "org/archive-failure",
        github_installation_id: 5803,
        linear_workspace_id: workspace.id,
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

    {:ok, issue} = Issues.capture_issue(scope, project, "Failing Archive Issue")

    LinearMock.mock_mutation_failure("issueUpdate")

    assert {:error, {:linear_mutation_failed, "issueUpdate"}} =
             Issues.archive_issue(scope, issue)
  end

  test "archive_issue/2 returns :not_authorized for nil scope" do
    issue = %Issue{project_id: "prj_1", external_id: "lin_1"}
    assert {:error, :not_authorized} = Issues.archive_issue(nil, issue)
  end
end
