defmodule Rail.Initiatives.Actions.DeleteInitiativeTest do
  use Rail.DataCase, async: true

  alias Rail.Initiatives
  alias Rail.Initiatives.Schemas.Initiative
  alias Rail.Initiatives.Schemas.InitiativeComment
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue

  setup %{project: project} do
    {:ok, initiative} =
      Initiatives.create_initiative(system_scope(), project, %{name: "Delete #{System.unique_integer([:positive])}"})

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Linked"})
    {:ok, issue} = Issues.set_issue_initiative(system_scope(), issue, initiative.id)
    {:ok, _brief} = Initiatives.create_update_brief(system_scope(), initiative)
    %{initiative: initiative, issue: issue}
  end

  test "deletes the initiative and its briefs, leaves its tickets with none, and tells each ticket's page", %{
    project: %{id: project_id},
    initiative: %{id: initiative_id} = initiative,
    issue: %{id: issue_id}
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "initiatives")
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    assert :ok = Initiatives.delete_initiative(user_scope(project_ids: [project_id]), initiative)

    assert_receive {:initiatives_changed, ^project_id}
    assert_receive {:issue_changed, ^issue_id}
    assert %Issue{initiative_id: nil} = Repo.get!(Issue, issue_id)
    refute Repo.get(Initiative, initiative_id)
    assert [] = Repo.all(from(c in InitiativeComment, where: c.initiative_id == ^initiative_id))
  end

  test "a scope without the project, or a second delete, is not found and broadcasts nothing", %{
    initiative: %{id: initiative_id} = initiative,
    issue: %{id: issue_id}
  } do
    assert {:error, :not_found} = Initiatives.delete_initiative(temp_user_scope(project_ids: []), initiative)
    assert %Issue{initiative_id: ^initiative_id} = Repo.get!(Issue, issue_id)

    :ok = Initiatives.delete_initiative(system_scope(), initiative)
    Phoenix.PubSub.subscribe(Rail.PubSub, "initiatives")

    assert {:error, :not_found} = Initiatives.delete_initiative(system_scope(), initiative)
    refute_received {:initiatives_changed, _project_id}
  end
end
