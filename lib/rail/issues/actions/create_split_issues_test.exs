defmodule Rail.Issues.Actions.CreateSplitIssuesTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.TicketBody
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User
  alias RailTest.Mocks.Linear, as: LinearMock

  test "create_split_issues/4 creates multiple split tickets in Linear and mirrors locally" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    project =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          linear_team_id: "team_split_1",
          linear_state_ids: %{"triage" => "st_triage_split"}
      })

    owner =
      Repo.insert!(%{
        User.factory()
        | linear_access_token: "lin_split_owner_tok",
          linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_split_1",
      "identifier" => "ENG-901",
      "title" => "Split Ticket 1",
      "description" => "Description 1",
      "state" => %{"id" => "st_triage_split", "name" => "Triage", "type" => "triage"},
      "branchName" => "eng-901-branch",
      "url" => "https://linear.app/issue/ENG-901",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_split_2",
      "identifier" => "ENG-902",
      "title" => "Split Ticket 2",
      "description" => "Description 2",
      "state" => %{"id" => "st_triage_split", "name" => "Triage", "type" => "triage"},
      "branchName" => "eng-902-branch",
      "url" => "https://linear.app/issue/ENG-902",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_split_3",
      "identifier" => "ENG-903",
      "title" => "Atom Title",
      "description" => "Atom Desc",
      "state" => %{"id" => "st_triage_split", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-903",
      "createdAt" => nil,
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_split_4",
      "identifier" => "ENG-904",
      "title" => "String Title",
      "description" => "String Desc",
      "state" => %{"id" => "st_triage_split", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-904",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "invalid-iso"
    })

    splits = [
      %TicketBody{title: "Split Ticket 1", description: "Description 1"},
      %{"title" => "Split Ticket 2", "description" => "Description 2"},
      %{title: "Atom Title", description: "Atom Desc"},
      "# String Title\n\nString Desc"
    ]

    scope = Scope.for_user(owner)

    assert {:ok,
            [
              %Issue{external_id: "lin_split_1", identifier: "ENG-901", state: :triage},
              %Issue{external_id: "lin_split_2", identifier: "ENG-902", state: :triage},
              %Issue{external_id: "lin_split_3", identifier: "ENG-903", state: :triage},
              %Issue{external_id: "lin_split_4", identifier: "ENG-904", state: :triage}
            ]} = Issues.create_split_issues(scope, project, splits, owner)
  end

  test "create_split_issues/3 supports map of split files" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    project =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          linear_team_id: "team_split_2",
          linear_state_ids: %{"triage" => "st_triage_split"}
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_split_5",
      "identifier" => "ENG-905",
      "title" => "Map Split",
      "description" => "Body",
      "state" => %{"id" => "st_triage_split", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-905",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    split_map = %{"split-1.md" => "# Map Split\n\nBody"}
    scope = Scope.for_system()

    assert {:ok, [%Issue{external_id: "lin_split_5"}]} =
             Issues.create_split_issues(scope, project, split_map)
  end

  test "create_split_issues/4 rolls back on Linear creation failure" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id})

    LinearMock.mock_mutation_failure("issueCreate")
    scope = Scope.for_system()

    assert {:error, {:linear_mutation_failed, "issueCreate"}} =
             Issues.create_split_issues(scope, project, [%TicketBody{title: "Failing"}])
  end

  test "create_split_issues/3 returns :not_authorized for nil scope" do
    project = Repo.insert!(Project.factory())
    assert {:error, :not_authorized} = Issues.create_split_issues(nil, project, [])
  end
end
