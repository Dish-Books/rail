defmodule Rail.Initiatives.Actions.GetInitiativeTest do
  use Rail.DataCase, async: true

  alias Rail.Initiatives
  alias Rail.Initiatives.Schemas.Initiative
  alias Rail.Initiatives.Schemas.InitiativeComment
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue

  @done %{id: "done", name: "Done", state: :done}

  test "reads the initiative with its counts, its tickets by number with what each needs, and its briefs newest first",
       %{project: project} do
    {:ok, %{id: initiative_id} = initiative} =
      Initiatives.create_initiative(system_scope(), project, %{name: "Get #{System.unique_integer([:positive])}"})

    [%{id: first_id}, %{id: second_id}] =
      for title <- ["First", "Second"] do
        {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: title})
        {:ok, issue} = Issues.set_issue_initiative(system_scope(), issue, initiative.id)
        issue
      end

    {:ok, _issue} = Issues.set_issue_status(system_scope(), %Issue{id: second_id, project_id: project.id}, @done)
    {:ok, %{id: older_id}} = Initiatives.create_update_brief(system_scope(), initiative)
    {:ok, %{id: newer_id}} = Initiatives.create_update_brief(system_scope(), initiative)

    assert {:ok,
            %Initiative{
              id: ^initiative_id,
              done_count: 1,
              ticket_count: 2,
              issues: [%Issue{id: ^first_id, owner_user: nil}, %Issue{id: ^second_id}],
              comments: [%InitiativeComment{id: ^newer_id}, %InitiativeComment{id: ^older_id, author_user: nil}]
            }} = Initiatives.get_initiative(system_scope(), initiative_id, preload: [:owner_user])
  end

  test "an initiative in a project the scope cannot open, or none at all, is not found", %{project: project} do
    {:ok, initiative} =
      Initiatives.create_initiative(system_scope(), project, %{name: "Hidden #{System.unique_integer([:positive])}"})

    assert {:error, :not_found} = Initiatives.get_initiative(temp_user_scope(project_ids: []), initiative.id)
    assert {:ok, %Initiative{}} = Initiatives.get_initiative(temp_user_scope(project_ids: [project.id]), initiative.id)
    assert {:error, :not_found} = Initiatives.get_initiative(system_scope(), "ini_missing")
  end
end
