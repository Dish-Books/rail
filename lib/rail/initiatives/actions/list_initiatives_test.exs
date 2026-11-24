defmodule Rail.Initiatives.Actions.ListInitiativesTest do
  use Rail.DataCase, async: true

  alias Rail.Initiatives
  alias Rail.Initiatives.Schemas.Initiative
  alias Rail.Issues
  alias Rail.Projects

  @done %{id: "done", name: "Done", state: :done}
  @canceled %{id: "canceled", name: "Canceled", state: :canceled}

  setup do
    projects =
      for name <- ["Listed", "Other"] do
        key = "LI#{System.unique_integer([:positive])}"

        {:ok, project} =
          Projects.create_project(system_scope(), %{
            name: name,
            github_repo: "example/#{key}",
            github_installation_id: 1,
            key: key,
            default_branch: "main",
            clone_path: "/tmp/#{key}"
          })

        project
      end

    %{projects: projects}
  end

  test "counts Done tickets out of every one not Canceled, leaving out other initiatives' tickets", %{
    projects: [%{id: listed_id} = listed, _other]
  } do
    {:ok, %{id: credo_id} = credo} = Initiatives.create_initiative(system_scope(), listed, %{name: "Credo"})
    {:ok, %{id: payroll_id} = payroll} = Initiatives.create_initiative(system_scope(), listed, %{name: "Payroll"})

    for status <- [@done, nil, nil, @canceled] do
      {:ok, issue} = Issues.create_issue(system_scope(), listed, %{title: "Credo work"})
      {:ok, issue} = Issues.set_issue_initiative(system_scope(), issue, credo.id)
      if status, do: {:ok, _issue} = Issues.set_issue_status(system_scope(), issue, status)
    end

    {:ok, payroll_issue} = Issues.create_issue(system_scope(), listed, %{title: "Payroll work"})
    {:ok, payroll_issue} = Issues.set_issue_initiative(system_scope(), payroll_issue, payroll.id)
    {:ok, _issue} = Issues.set_issue_status(system_scope(), payroll_issue, @done)
    {:ok, _loose} = Issues.create_issue(system_scope(), listed, %{title: "In none"})

    assert [
             %Initiative{id: ^credo_id, done_count: 1, ticket_count: 3, project: %{id: ^listed_id}},
             %Initiative{id: ^payroll_id, done_count: 1, ticket_count: 1}
           ] = Initiatives.list_initiatives(system_scope(), project_id: listed.id)
  end

  test "lists only the projects the scope can open, and narrows to the ids it is given", %{
    projects: [listed, other]
  } do
    {:ok, %{id: listed_id}} = Initiatives.create_initiative(system_scope(), listed, %{name: "Mine"})
    {:ok, %{id: other_id}} = Initiatives.create_initiative(system_scope(), other, %{name: "Theirs"})

    assert [%Initiative{id: ^listed_id}] =
             Initiatives.list_initiatives(temp_user_scope(project_ids: [listed.id]), project_id: [listed.id, other.id])

    assert [] = Initiatives.list_initiatives(temp_user_scope(project_ids: [listed.id]), project_id: other.id)
    assert [] = Initiatives.list_initiatives(temp_user_scope(project_ids: []))

    assert [%Initiative{id: ^listed_id}, %Initiative{id: ^other_id}] =
             Initiatives.list_initiatives(system_scope(), project_id: [listed.id, other.id], sort: :name)
  end

  test "sorts by expected date with none last, by name, or by progress, each ending on name", %{
    projects: [listed, _other]
  } do
    {:ok, %{id: late_id}} =
      Initiatives.create_initiative(system_scope(), listed, %{name: "Zebra", expected_on: ~D[2026-11-20]})

    {:ok, %{id: soon_id}} =
      Initiatives.create_initiative(system_scope(), listed, %{name: "apple", expected_on: ~D[2026-12-12]})

    {:ok, %{id: none_id} = none} = Initiatives.create_initiative(system_scope(), listed, %{name: "Mango"})
    {:ok, %{id: empty_id}} = Initiatives.create_initiative(system_scope(), listed, %{name: "Banana"})

    {:ok, issue} = Issues.create_issue(system_scope(), listed, %{title: "Done work"})
    {:ok, issue} = Issues.set_issue_initiative(system_scope(), issue, none.id)
    {:ok, _issue} = Issues.set_issue_status(system_scope(), issue, @done)

    ids = fn sort ->
      Enum.map(Initiatives.list_initiatives(system_scope(), project_id: listed.id, sort: sort), & &1.id)
    end

    assert ids.(:expected) == [late_id, soon_id, empty_id, none_id]
    assert Enum.map(Initiatives.list_initiatives(system_scope(), project_id: listed.id), & &1.id) == ids.(:expected)
    assert ids.(:name) == [soon_id, empty_id, none_id, late_id]
    assert ids.(:progress) == [none_id, soon_id, empty_id, late_id]
  end
end
