defmodule Rail.Initiatives.Actions.UpdateInitiativeTest do
  use Rail.DataCase, async: true

  alias Rail.Initiatives
  alias Rail.Initiatives.Schemas.Initiative

  setup %{project: project} do
    {:ok, initiative} =
      Initiatives.create_initiative(system_scope(), project, %{
        name: "Update #{System.unique_integer([:positive])}",
        expected_on: ~D[2026-12-12]
      })

    Phoenix.PubSub.subscribe(Rail.PubSub, "initiatives")
    %{initiative: initiative}
  end

  test "writes the notes, name and date over the initiative as it now reads, and broadcasts", %{
    project: %{id: project_id},
    initiative: %{id: initiative_id} = initiative
  } do
    {:ok, _renamed} = Initiatives.update_initiative(system_scope(), initiative, %{name: "#{initiative.name} renamed"})
    name = "#{initiative.name} renamed"

    assert {:ok, %Initiative{id: ^initiative_id, name: ^name, notes: "### Plan", expected_on: nil}} =
             Initiatives.update_initiative(user_scope(project_ids: [project_id]), initiative, %{
               "notes" => "### Plan",
               "expected_on" => ""
             })

    assert_receive {:initiatives_changed, ^project_id}
  end

  test "an invalid name is the changeset's error, and a scope without the project or a deleted one is not found", %{
    initiative: initiative
  } do
    assert {:error, changeset} = Initiatives.update_initiative(system_scope(), initiative, %{name: ""})
    assert %{name: ["can't be blank"]} = errors_on(changeset)

    assert {:error, :not_found} =
             Initiatives.update_initiative(temp_user_scope(project_ids: []), initiative, %{notes: "No"})

    :ok = Initiatives.delete_initiative(system_scope(), initiative)
    assert {:error, :not_found} = Initiatives.update_initiative(system_scope(), initiative, %{notes: "Gone"})
  end
end
