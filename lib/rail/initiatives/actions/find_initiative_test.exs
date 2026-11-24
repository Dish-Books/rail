defmodule Rail.Initiatives.Actions.FindInitiativeTest do
  use Rail.DataCase, async: true

  alias Rail.Initiatives
  alias Rail.Initiatives.Schemas.Initiative
  alias Rail.Projects

  setup do
    key = "FI#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Found",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    %{local: project, key: key}
  end

  test "finds the project's initiative by name in any case and with spaces around it", %{local: local} do
    {:ok, %{id: credo_id}} = Initiatives.create_initiative(system_scope(), local, %{name: "Credo exclusions"})

    assert {:ok, %Initiative{id: ^credo_id}} =
             Initiatives.find_initiative(system_scope(), local, "  credo EXCLUSIONS ")
  end

  test "an unknown name names the project's initiatives, or says it has none", %{local: local, key: key} do
    none = "names none: #{key} has no initiatives"
    assert {:error, {:invalid, :initiative, ^none}} = Initiatives.find_initiative(system_scope(), local, "Credo")

    {:ok, _credo} = Initiatives.create_initiative(system_scope(), local, %{name: "Credo exclusions"})
    {:ok, _payroll} = Initiatives.create_initiative(system_scope(), local, %{name: "Payroll v2"})

    listed = "is not one in #{key}: Credo exclusions, Payroll v2"
    assert {:error, {:invalid, :initiative, ^listed}} = Initiatives.find_initiative(system_scope(), local, "Credo")
  end

  test "a scope that cannot open the project finds none of its initiatives", %{local: local} do
    {:ok, _credo} = Initiatives.create_initiative(system_scope(), local, %{name: "Credo exclusions"})

    assert {:error, {:invalid, :initiative, "names none: " <> _key}} =
             Initiatives.find_initiative(temp_user_scope(project_ids: []), local, "Credo exclusions")
  end
end
