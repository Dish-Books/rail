defmodule Rail.Issues.Actions.SetIssueInitiativeTest do
  use Rail.DataCase, async: true

  alias Rail.Initiatives
  alias Rail.Issues
  alias Rail.Issues.Schemas.Cycle
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects

  setup do
    [local, other] =
      for name <- ["Grouped", "Elsewhere"] do
        key = "SII#{System.unique_integer([:positive])}"

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

    {:ok, initiative} = Initiatives.create_initiative(system_scope(), local, %{name: "Credo exclusions"})
    {:ok, foreign} = Initiatives.create_initiative(system_scope(), other, %{name: "Credo exclusions"})
    {:ok, parent} = Issues.create_issue(system_scope(), local, %{title: "Umbrella"})

    %Cycle{id: cycle_id} =
      Repo.insert!(%Cycle{project_id: local.id, number: 1, starts_on: ~D[2026-11-24], ends_on: ~D[2026-12-07]})

    {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "A part", parent: parent, cycle_id: cycle_id})
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
    Phoenix.PubSub.subscribe(Rail.PubSub, "initiatives")

    %{local: local, initiative: initiative, foreign: foreign, issue: issue, parent: parent, cycle_id: cycle_id}
  end

  test "puts a sub-issue in its project's initiative with its parent and cycle kept, and takes it out again", %{
    local: %{id: project_id},
    initiative: %{id: initiative_id},
    issue: %{id: issue_id} = issue,
    parent: %{id: parent_id},
    cycle_id: cycle_id
  } do
    assert {:ok, %Issue{id: ^issue_id, initiative_id: ^initiative_id, parent_id: ^parent_id, cycle_id: ^cycle_id}} =
             Issues.set_issue_initiative(user_scope(project_ids: [project_id]), issue, initiative_id)

    assert_receive {:issue_changed, ^issue_id}
    assert_receive {:initiatives_changed, ^project_id}

    assert {:ok, %Issue{initiative_id: ^initiative_id}} =
             Issues.set_issue_initiative(system_scope(), issue, initiative_id)

    refute_receive {:issue_changed, ^issue_id}

    assert {:ok, %Issue{initiative_id: nil}} = Issues.set_issue_initiative(system_scope(), issue, nil)
    assert %Issue{initiative_id: nil, parent_id: ^parent_id, cycle_id: ^cycle_id} = Repo.get!(Issue, issue_id)
  end

  test "another project's initiative, or a deleted one, is refused and the issue keeps its own", %{
    initiative: %{id: initiative_id} = initiative,
    foreign: foreign,
    issue: %{id: issue_id} = issue
  } do
    {:ok, _issue} = Issues.set_issue_initiative(system_scope(), issue, initiative_id)

    assert {:error, :not_found} = Issues.set_issue_initiative(system_scope(), issue, foreign.id)
    assert %Issue{initiative_id: ^initiative_id} = Repo.get!(Issue, issue_id)

    :ok = Initiatives.delete_initiative(system_scope(), initiative)
    assert {:error, :not_found} = Issues.set_issue_initiative(system_scope(), issue, initiative_id)
    assert %Issue{initiative_id: nil} = Repo.get!(Issue, issue_id)
  end

  test "a scope that cannot open the project, or an issue that is gone, is not found", %{
    initiative: initiative,
    issue: issue
  } do
    assert {:error, :not_found} =
             Issues.set_issue_initiative(temp_user_scope(project_ids: []), issue, initiative.id)

    assert {:error, :not_found} =
             Issues.set_issue_initiative(system_scope(), %{issue | id: "iss_missing"}, initiative.id)
  end
end
