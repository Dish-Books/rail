defmodule Rail.Issues.Actions.PushTicketTest do
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
        name: "Push Ticket Workspace",
        external_id: "lin_ws_push_ticket",
        token: "lin_api_token_push_ticket",
        webhook_secret: "whsec_push_ticket"
      })

    %{workspace: workspace}
  end

  test "push_ticket/5 parses ticket body and updates Linear and local issue with owner user", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Push Ticket Project 6301",
        github_repo: "org/push-ticket-6301",
        github_installation_id: 6301,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_push_1",
        linear_team_key: "PT1",
        clone_path: "/tmp/repos/push-ticket-6301"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_push_1",
      "identifier" => "ENG-801",
      "title" => "Initial",
      "description" => "Initial body",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/Push Ticket",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Initial")

    {:ok, owner} =
      Users.register_oauth_user(%{
        github_id: "gh_push_ticket_6303",
        login: "push_ticket_user_6303",
        email: "push_ticket_user_6303@example.com"
      })

    {:ok, owner} =
      Users.link_linear(owner, %{
        access_token: "lin_owner_token",
        refresh_token: "lin_refresh_6303",
        expires_in: 3600
      })

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_push_1",
      "identifier" => "ENG-801",
      "title" => "Refactored Feature Title",
      "description" => "Detailed specification and acceptance criteria.",
      "state" => %{"id" => "st_1", "name" => "Triage", "type" => "triage"},
      "branchName" => "eng-801-branch",
      "url" => issue.url,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-03T10:00:00.000Z"
    })

    ticket_content = """
    # Refactored Feature Title

    Detailed specification and acceptance criteria.
    """

    scope = Scope.for_system()

    assert {:ok,
            %Issue{
              title: "Refactored Feature Title",
              description: "Detailed specification and acceptance criteria."
            }} = Issues.push_ticket(scope, project, "ENG-801", ticket_content, owner)
  end

  test "push_ticket/4 works with user scope and handles nil and invalid updatedAt", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Push Ticket Project 6304",
        github_repo: "org/push-ticket-6304",
        github_installation_id: 6304,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_push_2",
        linear_team_key: "PT4",
        clone_path: "/tmp/repos/push-ticket-6304"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_push_user",
      "identifier" => "ENG-803",
      "title" => "Initial",
      "description" => "Initial body",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/Push Ticket",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Initial")

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_push_ticket_6306",
        login: "push_ticket_user_6306",
        email: "push_ticket_user_6306@example.com"
      })

    {:ok, user} =
      Users.link_linear(user, %{
        access_token: "lin_push_user_tok",
        refresh_token: "lin_refresh_6306",
        expires_in: 3600
      })

    scope = Scope.for_user(user)

    # First with invalid date string
    LinearMock.mock_update_issue_success(%{
      "id" => "lin_push_user",
      "identifier" => "ENG-803",
      "title" => "User Push Title",
      "description" => "User Push Body",
      "state" => %{"id" => "st_1", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => issue.url,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "invalid-iso-string"
    })

    assert {:ok, %Issue{title: "User Push Title"}} =
             Issues.push_ticket(scope, project, "ENG-803", "# User Push Title\n\nUser Push Body")

    # Second with nil updatedAt
    LinearMock.mock_update_issue_success(%{
      "id" => "lin_push_user",
      "identifier" => "ENG-803",
      "title" => "User Push Title 2",
      "description" => "User Push Body 2",
      "state" => %{"id" => "st_1", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => issue.url,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => nil
    })

    assert {:ok, %Issue{title: "User Push Title 2"}} =
             Issues.push_ticket(scope, project, "ENG-803", "# User Push Title 2\n\nUser Push Body 2")
  end

  test "push_ticket/4 returns {:error, :not_found} when identifier does not exist", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Push Ticket Project 6307",
        github_repo: "org/push-ticket-6307",
        github_installation_id: 6307,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_push_ticket_6307",
        linear_team_key: "PT7",
        clone_path: "/tmp/repos/push-ticket-6307"
      })

    scope = Scope.for_system()

    assert {:error, :not_found} =
             Issues.push_ticket(scope, project, "ENG-NONEXISTENT", "# Title\n\nBody")
  end

  test "push_ticket/4 returns error on Linear mutation failure", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Push Ticket Project 6308",
        github_repo: "org/push-ticket-6308",
        github_installation_id: 6308,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_push_ticket_6308",
        linear_team_key: "PT8",
        clone_path: "/tmp/repos/push-ticket-6308"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_push_fail",
      "identifier" => "ENG-802",
      "title" => "Push Ticket Issue 6309",
      "description" => "Push Ticket Issue 6309",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/Push Ticket",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    {:ok, _issue} = Issues.capture_issue(system_scope(), project, "Push Ticket Issue 6309")

    LinearMock.mock_mutation_failure("issueUpdate")
    scope = Scope.for_system()

    assert {:error, {:linear_mutation_failed, "issueUpdate"}} =
             Issues.push_ticket(scope, project, "ENG-802", "# Title\n\nBody")
  end

  test "push_ticket/4 returns :not_authorized for nil scope", %{workspace: workspace} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Push Ticket Project 6310",
        github_repo: "org/push-ticket-6310",
        github_installation_id: 6310,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_push_ticket_6310",
        linear_team_key: "PT10",
        clone_path: "/tmp/repos/push-ticket-6310"
      })

    assert {:error, :not_authorized} = Issues.push_ticket(nil, project, "ENG-1", "content")
  end
end
