defmodule Rail.Issues.Actions.PushTicketTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User
  alias RailTest.Mocks.Linear, as: LinearMock

  test "push_ticket/5 parses ticket body and updates Linear and local issue with owner user" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id, linear_team_id: "team_push_1"})

    issue =
      Repo.insert!(%{
        Issue.factory()
        | project_id: project.id,
          external_id: "lin_push_1",
          identifier: "ENG-801",
          title: "Initial",
          description: "Initial body"
      })

    owner =
      Repo.insert!(%{
        User.factory()
        | linear_access_token: "lin_owner_token",
          linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
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

  test "push_ticket/4 works with user scope and handles nil and invalid updatedAt" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id, linear_team_id: "team_push_2"})

    issue =
      Repo.insert!(%{
        Issue.factory()
        | project_id: project.id,
          external_id: "lin_push_user",
          identifier: "ENG-803",
          title: "Initial",
          description: "Initial body"
      })

    user =
      Repo.insert!(%{
        User.factory()
        | linear_access_token: "lin_push_user_tok",
          linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
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

  test "push_ticket/4 returns {:error, :not_found} when identifier does not exist" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id})

    scope = Scope.for_system()

    assert {:error, :not_found} =
             Issues.push_ticket(scope, project, "ENG-NONEXISTENT", "# Title\n\nBody")
  end

  test "push_ticket/4 returns error on Linear mutation failure" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id})

    Repo.insert!(%{
      Issue.factory()
      | project_id: project.id,
        external_id: "lin_push_fail",
        identifier: "ENG-802"
    })

    LinearMock.mock_mutation_failure("issueUpdate")
    scope = Scope.for_system()

    assert {:error, {:linear_mutation_failed, "issueUpdate"}} =
             Issues.push_ticket(scope, project, "ENG-802", "# Title\n\nBody")
  end

  test "push_ticket/4 returns :not_authorized for nil scope" do
    project = Repo.insert!(Project.factory())
    assert {:error, :not_authorized} = Issues.push_ticket(nil, project, "ENG-1", "content")
  end
end
