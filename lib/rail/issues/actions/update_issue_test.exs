defmodule Rail.Issues.Actions.UpdateIssueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User
  alias RailTest.Mocks.Linear, as: LinearMock

  test "update_issue/3 updates title, description, and state in Linear and DB" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    project =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          linear_team_id: "team_up_1",
          linear_state_ids: %{"in_progress" => "st_prog_1"}
      })

    issue =
      Repo.insert!(%{
        Issue.factory()
        | project_id: project.id,
          external_id: "lin_up_1",
          identifier: "ENG-601",
          title: "Initial Title",
          state: :triage
      })

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

  test "update_issue/3 works with user scope, explicit state_id, and keyword list attrs" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id})

    issue =
      Repo.insert!(%{
        Issue.factory()
        | project_id: project.id,
          external_id: "lin_up_user",
          identifier: "ENG-602"
      })

    user =
      Repo.insert!(%{
        User.factory()
        | linear_access_token: "lin_up_user_tok",
          linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
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

  test "update_issue/3 ignores state when not mapped in project linear_state_ids" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id, linear_state_ids: %{}})
    issue = Repo.insert!(%{Issue.factory() | project_id: project.id, external_id: "lin_up_nostate"})

    scope = Scope.for_system()

    assert {:ok, %Issue{state: :done}} =
             Issues.update_issue(scope, issue, %{state: :done})
  end

  test "update_issue/3 succeeds with empty linear attrs" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id})

    issue =
      Repo.insert!(%{
        Issue.factory()
        | project_id: project.id,
          external_id: "lin_up_2",
          url: "https://linear.app/old"
      })

    scope = Scope.for_system()

    assert {:ok, %Issue{url: "https://linear.app/new"}} =
             Issues.update_issue(scope, issue, %{url: "https://linear.app/new"})
  end

  test "update_issue/3 returns error when Linear update fails" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id})

    issue = Repo.insert!(%{Issue.factory() | project_id: project.id, external_id: "lin_up_3"})
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
