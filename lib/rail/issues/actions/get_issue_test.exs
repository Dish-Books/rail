defmodule Rail.Issues.Actions.GetIssueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  test "get_issue/2 retrieves an existing issue by id and external_id" do
    %Project{id: project_id} = Repo.insert!(Project.factory())

    %Issue{id: issue_id} =
      Repo.insert!(%{
        Issue.factory()
        | project_id: project_id,
          external_id: "lin_get_1",
          identifier: "ENG-401",
          title: "Get Issue Test"
      })

    scope = Scope.for_user(%{admin: false})

    assert {:ok, %Issue{id: ^issue_id, title: "Get Issue Test"}} =
             Issues.get_issue(scope, issue_id)

    assert {:ok, %Issue{id: ^issue_id, title: "Get Issue Test"}} =
             Issues.get_issue(scope, "lin_get_1")
  end

  test "get_issue/2 returns {:error, :not_found} when issue does not exist" do
    scope = Scope.for_system()
    assert {:error, :not_found} = Issues.get_issue(scope, "iss_nonexistent")
  end

  test "get_issue/2 returns :not_authorized for nil scope" do
    assert {:error, :not_authorized} = Issues.get_issue(nil, "iss_123")
  end

  test "get_issue!/2 retrieves issue or raises error" do
    %Project{id: project_id} = Repo.insert!(Project.factory())
    %Issue{id: issue_id} = Repo.insert!(%{Issue.factory() | project_id: project_id, identifier: "ENG-402"})

    scope = Scope.for_system()
    assert %Issue{id: ^issue_id} = Issues.get_issue!(scope, issue_id)

    assert_raise Ecto.NoResultsError, fn ->
      Issues.get_issue!(scope, "iss_missing_123")
    end

    assert_raise RuntimeError, "Unauthorized", fn ->
      Issues.get_issue!(nil, issue_id)
    end
  end
end
