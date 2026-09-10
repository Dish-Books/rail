defmodule Rail.Issues.Actions.ListIssuesTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  test "list_issues lists issues for project with default show_finished: false" do
    %Project{id: project_id_1} = project_1 = Repo.insert!(Project.factory())
    %Project{id: project_id_2} = Repo.insert!(Project.factory())

    %Issue{id: id1} =
      Repo.insert!(%{Issue.factory() | project_id: project_id_1, identifier: "ENG-501", state: :triage})

    %Issue{id: id2} =
      Repo.insert!(%{Issue.factory() | project_id: project_id_1, identifier: "ENG-502", state: :done})

    _issue_3 =
      Repo.insert!(%{Issue.factory() | project_id: project_id_2, identifier: "ENG-503", state: :in_progress})

    scope = Scope.for_user(%{admin: false})

    # Default show_finished: false excludes done issue id2
    assert [%Issue{id: ^id1}] = Issues.list_issues(scope, project_1)

    # Explicit show_finished: true includes done issue id2
    assert [%Issue{id: ^id1}, %Issue{id: ^id2}] =
             Issues.list_issues(scope, project_id: project_id_1, show_finished: true)

    # 3-arity list_issues with project struct and opts
    assert [%Issue{id: ^id1}, %Issue{id: ^id2}] =
             Issues.list_issues(scope, project_1, show_finished: true)

    assert [%Issue{id: ^id1}] = Issues.list_issues(scope, project_id: project_id_1, state: :triage)

    # Preload option preloads associations
    assert [%Issue{id: ^id1, project: %Project{id: ^project_id_1}}] =
             Issues.list_issues(scope, project_id: project_id_1, preload: [:project])

    system_scope = Scope.for_system()
    assert length(Issues.list_issues(system_scope, show_finished: true)) == 3
    assert length(Issues.list_issues(system_scope, show_finished: false)) == 2
    assert length(Issues.list_issues(system_scope)) == 2
  end

  test "list_issues returns empty list for unauthorized scope" do
    assert [] == Issues.list_issues(nil, [])
    assert [] == Issues.list_issues(nil, %Project{id: "prj_test"}, [])
  end
end
