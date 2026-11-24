defmodule Rail.Initiatives.Actions.CreateInitiativeTest do
  use Rail.DataCase, async: true

  alias Rail.Initiatives
  alias Rail.Initiatives.Schemas.Initiative

  setup do
    Phoenix.PubSub.subscribe(Rail.PubSub, "initiatives")
    %{name: "Credo #{System.unique_integer([:positive])}"}
  end

  test "creates the initiative in the project and broadcasts it", %{project: %{id: project_id} = project, name: name} do
    assert {:ok, %Initiative{project_id: ^project_id, name: ^name, notes: "", expected_on: ~D[2026-12-12]}} =
             Initiatives.create_initiative(user_scope(project_ids: [project_id]), project, %{
               "name" => name,
               "expected_on" => "2026-12-12",
               "project_id" => "prj_elsewhere"
             })

    assert_receive {:initiatives_changed, ^project_id}
  end

  test "a name already in the project, in any case, is the changeset's error", %{project: project, name: name} do
    {:ok, _initiative} = Initiatives.create_initiative(system_scope(), project, %{name: name})

    assert {:error, changeset} = Initiatives.create_initiative(system_scope(), project, %{name: String.upcase(name)})
    assert %{name: ["is already an initiative here"]} = errors_on(changeset)
  end

  test "a project the scope cannot open is not found, and nothing is created", %{project: project, name: name} do
    assert {:error, :not_found} = Initiatives.create_initiative(temp_user_scope(project_ids: []), project, %{name: name})
    refute_received {:initiatives_changed, _project_id}
  end
end
