defmodule Rail.Projects.Actions.FindProjectTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project

  setup do
    projects =
      for name <- ["Planner", "Shared name", "Shared name"] do
        key = "Fp#{System.unique_integer([:positive])}"

        {:ok, project} =
          Projects.create_project(system_scope(), %{
            name: name,
            github_repo: "example/#{key}",
            github_installation_id: 1,
            tracker: :local,
            key: key,
            default_branch: "main",
            clone_path: "/tmp/#{key}"
          })

        project
      end

    %{projects: projects, scope: user_scope(project_ids: Enum.map(projects, & &1.id))}
  end

  test "finds a project by its key or its name, ignoring case and spaces", %{
    projects: [%Project{id: id, key: key} | _shared],
    scope: scope
  } do
    assert {:ok, %Project{id: ^id}} = Projects.find_project(scope, " #{String.downcase(key)} ")
    assert {:ok, %Project{id: ^id}} = Projects.find_project(scope, "PLANNER")
  end

  test "two projects with the name, or none, is not found with the keys the scope can use", %{
    projects: projects,
    scope: scope
  } do
    keys = projects |> Enum.map(& &1.key) |> Enum.sort()

    assert {:error, {:not_found, ^keys}} = Projects.find_project(scope, "Shared name")
    assert {:error, {:not_found, ^keys}} = Projects.find_project(scope, "Nothing")
  end

  test "a project the scope cannot open is not found", %{projects: [%Project{key: key} | _shared]} do
    assert {:error, {:not_found, []}} = Projects.find_project(user_scope(project_ids: []), key)
  end
end
