defmodule Rail.Issues.Actions.UpdateIssueTest do
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
        name: "Update Issue Workspace",
        external_id: "lin_ws_update_issue",
        token: "lin_api_token_update_issue",
        webhook_secret: "whsec_update_issue"
      })

    %{workspace: workspace}
  end

  test "update_issue/3 updates title, description, and state in Linear and DB", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Update Issue One",
        github_repo: "org/update-issue-one",
        github_installation_id: 5901,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_update_issue_one",
        linear_team_key: "U01",
        default_branch: "main",
        clone_path: "/tmp/repos/update-issue-one",
        linear_state_ids: %{"in_progress" => "st_prog_1"}
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_up_1",
      "identifier" => "ENG-601",
      "title" => "Initial Title",
      "description" => "Initial Title",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-601",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Initial Title")

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_up_1",
      "identifier" => "ENG-601",
      "title" => "Updated Title",
      "description" => "Updated Description",
      "state" => %{"id" => "st_prog_1", "name" => "In Progress", "type" => "started"},
      "branchName" => "eng-601-branch",
      "url" => "https://linear.app/issue/ENG-601",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-02T10:00:00.000Z"
    })

    scope = Scope.for_system()

    assert {:ok, %Issue{title: "Updated Title", description: "Updated Description", state: :in_progress}} =
             Issues.update_issue(scope, issue, %{
               title: "Updated Title",
               description: "Updated Description",
               state: :in_progress
             })
  end

  test "update_issue/3 works with user scope, explicit state_id, and keyword list attrs", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Update Issue User",
        github_repo: "org/update-issue-user",
        github_installation_id: 5902,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_update_issue_user",
        linear_team_key: "U02",
        default_branch: "main",
        clone_path: "/tmp/repos/update-issue-user"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_up_user",
      "identifier" => "ENG-602",
      "title" => "User Update Issue",
      "description" => "User Update Issue",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-602",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "User Update Issue")

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_update_issue_user",
        login: "update_issue_user",
        email: "update_issue_user@example.com"
      })

    {:ok, user} =
      Users.link_linear(user, %{
        access_token: "lin_up_user_tok",
        refresh_token: "lin_up_user_refresh",
        expires_in: 3600
      })

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_up_user",
      "identifier" => "ENG-602",
      "title" => "KW Title",
      "description" => issue.description,
      "state" => %{"id" => "st_custom_1", "name" => "Custom", "type" => "started"},
      "branchName" => nil,
      "url" => issue.url,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-02T10:00:00.000Z"
    })

    scope = Scope.for_user(user)

    assert {:ok, %Issue{title: "KW Title"}} =
             Issues.update_issue(scope, issue, title: "KW Title", state_id: "st_custom_1")
  end

  test "update_issue/3 ignores state when not mapped in project linear_state_ids", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Update Issue No State",
        github_repo: "org/update-issue-nostate",
        github_installation_id: 5903,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_update_issue_nostate",
        linear_team_key: "U03",
        default_branch: "main",
        clone_path: "/tmp/repos/update-issue-nostate"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_up_nostate",
      "identifier" => "ENG-603",
      "title" => "No State Issue",
      "description" => "No State Issue",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-603",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "No State Issue")

    scope = Scope.for_system()

    assert {:ok, %Issue{state: :done}} =
             Issues.update_issue(scope, issue, %{state: :done})
  end

  test "update_issue/3 succeeds with empty linear attrs", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Update Issue Empty Attrs",
        github_repo: "org/update-issue-empty",
        github_installation_id: 5904,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_update_issue_empty",
        linear_team_key: "U04",
        default_branch: "main",
        clone_path: "/tmp/repos/update-issue-empty"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_up_2",
      "identifier" => "ENG-604",
      "title" => "Empty Attrs Issue",
      "description" => "Empty Attrs Issue",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-604",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Empty Attrs Issue")

    scope = Scope.for_system()

    assert {:ok, %Issue{url: "https://linear.app/new"}} =
             Issues.update_issue(scope, issue, %{url: "https://linear.app/new"})
  end

  test "update_issue/3 returns error when Linear update fails", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Update Issue Failure",
        github_repo: "org/update-issue-failure",
        github_installation_id: 5905,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_update_issue_failure",
        linear_team_key: "U05",
        default_branch: "main",
        clone_path: "/tmp/repos/update-issue-failure"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_up_3",
      "identifier" => "ENG-605",
      "title" => "Failing Update Issue",
      "description" => "Failing Update Issue",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-605",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Failing Update Issue")

    LinearMock.mock_mutation_failure("issueUpdate")

    scope = Scope.for_system()

    assert {:error, {:linear_mutation_failed, "issueUpdate"}} =
             Issues.update_issue(scope, issue, %{title: "Fail"})
  end

  test "update_issue/3 returns :not_authorized for nil scope" do
    issue = %Issue{project_id: "prj_1", external_id: "lin_1"}
    assert {:error, :not_authorized} = Issues.update_issue(nil, issue, %{})
  end
end
