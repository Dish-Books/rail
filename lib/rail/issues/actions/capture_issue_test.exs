defmodule Rail.Issues.Actions.CaptureIssueTest do
  use Rail.DataCase, async: true

  import ExUnit.CaptureLog

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Users
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Capture Issue Workspace",
        external_id: "lin_ws_capture_issue",
        token: "lin_api_token_capture_issue",
        webhook_secret: "whsec_capture_issue"
      })

    %{workspace: workspace}
  end

  test "capture_issue/3 creates issue using capturer's token", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Capture Issue Project 6101",
        github_repo: "org/capture-issue-6101",
        github_installation_id: 6101,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_cap_1",
        linear_team_key: "CI1",
        clone_path: "/tmp/repos/capture-issue-6101",
        linear_state_ids: %{"triage" => "st_triage_1"}
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_capture_6102",
        login: "capture_user_6102",
        email: "capture_user_6102@example.com"
      })

    {:ok, user} =
      Users.link_linear(user, %{
        access_token: "lin_usr_token_valid",
        refresh_token: "lin_refresh_6102",
        expires_in: 3600
      })

    scope = Scope.for_user(user)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_captured_1",
      "identifier" => "ENG-301",
      "title" => "Short ask title",
      "description" => "Short ask title\nMore details here",
      "state" => %{"id" => "st_triage_1", "name" => "Triage", "type" => "triage"},
      "branchName" => "eng-301-branch",
      "url" => "https://linear.app/issue/ENG-301",
      "createdAt" => "2026-09-02T10:00:00.000Z",
      "updatedAt" => "2026-09-02T10:00:00.000Z"
    })

    assert {:ok,
            %Issue{
              id: "iss_" <> _id,
              external_id: "lin_captured_1",
              identifier: "ENG-301",
              title: "Short ask title",
              state: :triage,
              state_name: "Triage"
            }} = Issues.capture_issue(scope, project, "Short ask title\nMore details here")
  end

  test "capture_issue/3 falls back to workspace token and logs when user unlinked", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Capture Issue Project 6103",
        github_repo: "org/capture-issue-6103",
        github_installation_id: 6103,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_cap_2",
        linear_team_key: "CI3",
        clone_path: "/tmp/repos/capture-issue-6103",
        linear_state_ids: %{"triage" => "st_triage_2"}
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_capture_6104",
        login: "capture_user_6104",
        email: "capture_user_6104@example.com"
      })

    scope = Scope.for_user(user)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_captured_2",
      "identifier" => "ENG-302",
      "title" => "Fallback ask title",
      "description" => "Fallback ask title",
      "state" => %{"id" => "st_triage_2", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-302",
      "createdAt" => nil,
      "updatedAt" => "not-a-datetime"
    })

    log =
      capture_log(fn ->
        assert {:ok, %Issue{external_id: "lin_captured_2"}} =
                 Issues.capture_issue(scope, project, "Fallback ask title")
      end)

    assert log =~ "[rail] pushed to Linear as the workspace"
  end

  test "capture_issue/3 returns error when Linear creation fails", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Capture Issue Project 6105",
        github_repo: "org/capture-issue-6105",
        github_installation_id: 6105,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_capture_6105",
        linear_team_key: "CI5",
        clone_path: "/tmp/repos/capture-issue-6105"
      })

    LinearMock.mock_mutation_failure("issueCreate")

    scope = Scope.for_system()

    assert {:error, {:linear_mutation_failed, "issueCreate"}} =
             Issues.capture_issue(scope, project, "Failing ask")
  end

  test "capture_issue/3 returns :not_authorized for nil scope", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Capture Issue Project 6106",
        github_repo: "org/capture-issue-6106",
        github_installation_id: 6106,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_capture_6106",
        linear_team_key: "CI6",
        clone_path: "/tmp/repos/capture-issue-6106"
      })

    assert {:error, :not_authorized} = Issues.capture_issue(nil, project, "ask")
  end

  test "capture_issue/4 creates issue with specified atom priority", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Capture Issue Project 6107",
        github_repo: "org/capture-issue-6107",
        github_installation_id: 6107,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_cap_pri",
        linear_team_key: "CI7",
        clone_path: "/tmp/repos/capture-issue-6107",
        linear_state_ids: %{"triage" => "st_triage_pri"}
      })

    scope = Scope.for_system()

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_captured_pri_1",
      "identifier" => "ENG-303",
      "title" => "Urgent fix",
      "description" => "Urgent fix needed immediately",
      "state" => %{"id" => "st_triage_pri", "name" => "Triage", "type" => "triage"},
      "branchName" => "eng-303",
      "url" => "https://linear.app/issue/ENG-303",
      "createdAt" => "2026-09-02T10:00:00.000Z",
      "updatedAt" => "2026-09-02T10:00:00.000Z"
    })

    assert {:ok,
            %Issue{
              external_id: "lin_captured_pri_1",
              priority: :urgent
            }} = Issues.capture_issue(scope, project, "Urgent fix needed immediately", priority: :urgent)
  end

  test "capture_issue/4 casts string priority and falls back to medium on invalid priority", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Capture Issue Project 6108",
        github_repo: "org/capture-issue-6108",
        github_installation_id: 6108,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_cap_str",
        linear_team_key: "CI8",
        clone_path: "/tmp/repos/capture-issue-6108",
        linear_state_ids: %{"triage" => "st_triage_str"}
      })

    scope = Scope.for_system()

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_captured_pri_2",
      "identifier" => "ENG-304",
      "title" => "Low task",
      "description" => "Low task details",
      "state" => %{"id" => "st_triage_str", "name" => "Triage", "type" => "triage"},
      "branchName" => "eng-304",
      "url" => "https://linear.app/issue/ENG-304",
      "createdAt" => "2026-09-02T10:00:00.000Z",
      "updatedAt" => "2026-09-02T10:00:00.000Z"
    })

    assert {:ok,
            %Issue{
              external_id: "lin_captured_pri_2",
              priority: :low
            }} = Issues.capture_issue(scope, project, "Low task details", priority: "low")
  end

  test "capture_issue/4 falls back to medium on invalid priority", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Capture Issue Project 6109",
        github_repo: "org/capture-issue-6109",
        github_installation_id: 6109,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_cap_inv",
        linear_team_key: "CI9",
        clone_path: "/tmp/repos/capture-issue-6109",
        linear_state_ids: %{"triage" => "st_triage_inv"}
      })

    scope = Scope.for_system()

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_captured_pri_3",
      "identifier" => "ENG-305",
      "title" => "Invalid prio task",
      "description" => "Some description",
      "state" => %{"id" => "st_triage_inv", "name" => "Triage", "type" => "triage"},
      "branchName" => "eng-305",
      "url" => "https://linear.app/issue/ENG-305",
      "createdAt" => "2026-09-02T10:00:00.000Z",
      "updatedAt" => "2026-09-02T10:00:00.000Z"
    })

    assert {:ok,
            %Issue{
              external_id: "lin_captured_pri_3",
              priority: :medium
            }} = Issues.capture_issue(scope, project, "Some description", priority: "invalid_priority")
  end

  test "capture_issue/4 falls back to medium on nil priority", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Capture Issue Project 6110",
        github_repo: "org/capture-issue-6110",
        github_installation_id: 6110,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_cap_nil",
        linear_team_key: "CI10",
        clone_path: "/tmp/repos/capture-issue-6110",
        linear_state_ids: %{"triage" => "st_triage_nil"}
      })

    scope = Scope.for_system()

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_captured_pri_4",
      "identifier" => "ENG-306",
      "title" => "Nil prio task",
      "description" => "Nil priority description",
      "state" => %{"id" => "st_triage_nil", "name" => "Triage", "type" => "triage"},
      "branchName" => "eng-306",
      "url" => "https://linear.app/issue/ENG-306",
      "createdAt" => "2026-09-02T10:00:00.000Z",
      "updatedAt" => "2026-09-02T10:00:00.000Z"
    })

    assert {:ok,
            %Issue{
              external_id: "lin_captured_pri_4",
              priority: :medium
            }} = Issues.capture_issue(scope, project, "Nil priority description", priority: nil)
  end
end
