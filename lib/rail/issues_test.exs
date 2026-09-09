defmodule Rail.IssuesTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  test "top-level Rail.Issues delegates read and write functions" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id})

    issue =
      Repo.insert!(%{
        Issue.factory()
        | project_id: project.id,
          external_id: "lin_top_1",
          identifier: "ENG-1111",
          title: "Top Issue"
      })

    scope = Scope.for_system()

    assert {:ok, %Issue{identifier: "ENG-1111"}} = Issues.get_issue(scope, issue.id)
    assert [%Issue{identifier: "ENG-1111"}] = Issues.list_issues(scope, project)
  end
end
