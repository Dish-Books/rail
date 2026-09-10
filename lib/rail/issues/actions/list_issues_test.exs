defmodule Rail.Issues.Actions.ListIssuesTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  test "list_issues/2 lists issues for project" do
    %Project{id: project_id_1} = project_1 = Repo.insert!(Project.factory())
    %Project{id: project_id_2} = Repo.insert!(Project.factory())

    %Issue{id: id1} = Repo.insert!(%{Issue.factory() | project_id: project_id_1, identifier: "ENG-501", state: :triage})
    %Issue{id: id2} = Repo.insert!(%{Issue.factory() | project_id: project_id_1, identifier: "ENG-502", state: :done})
    _issue_3 = Repo.insert!(%{Issue.factory() | project_id: project_id_2, identifier: "ENG-503", state: :in_progress})

    scope = Scope.for_user(%{admin: false})

    assert [%Issue{id: ^id1}, %Issue{id: ^id2}] = Issues.list_issues(scope, project_1)

    assert [%Issue{id: ^id1}] = Issues.list_issues(scope, project_id: project_id_1, show_finished: false)
    assert [%Issue{id: ^id1}] = Issues.list_issues(scope, project_id: project_id_1, state: :triage)

    system_scope = Scope.for_system()
    assert length(Issues.list_issues(system_scope)) == 3
  end

  test "list_issues/2 returns empty list for unauthorized scope" do
    assert [] == Issues.list_issues(nil, [])
  end
end
