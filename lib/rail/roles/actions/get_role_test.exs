defmodule Rail.Roles.Actions.GetRoleTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  setup do
    {:ok, backend} =
      Rail.Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Get Role Project",
        github_repo: "org/get-role",
        github_installation_id: 4102,
        linear_team_id: "team_get_role",
        linear_team_key: "GTR",
        default_branch: "main",
        clone_path: "/tmp/repos/get-role"
      })

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        name: "Engineer",
        stage: :engineer,
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert engineer."
      })

    %{project: project, role: role}
  end

  test "returns role by id", %{role: %Role{id: role_id} = role} do
    assert {:ok, %Role{id: ^role_id}} = Roles.get_role(id: role.id)
  end

  test "returns role by other fields", %{project: project, role: %Role{id: role_id}} do
    assert {:ok, %Role{id: ^role_id}} = Roles.get_role(project_id: project.id, stage: :engineer)
    assert {:ok, %Role{id: ^role_id}} = Roles.get_role(name: "Engineer")
  end

  test "returns role_not_found when role does not exist" do
    assert {:error, :role_not_found} = Roles.get_role(id: "rol_000000000000000000000000")
  end

  test "returns role_not_found when no role matches the criteria", %{project: project} do
    assert {:error, :role_not_found} = Roles.get_role(project_id: project.id, stage: :design)
  end
end
