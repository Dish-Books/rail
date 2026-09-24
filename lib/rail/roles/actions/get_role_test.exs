defmodule Rail.Roles.Actions.GetRoleTest do
  use Rail.DataCase, async: true

  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  setup do
    project =
      %Project{}
      |> Project.changeset(%{
        name: "Get Role Project",
        github_repo: "org/get-role",
        github_installation_id: 4404,
        linear_team_key: "GRL",
        default_branch: "main",
        clone_path: "/tmp/repos/get-role"
      })
      |> Repo.insert!()

    {:ok, backend} =
      Rail.Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        name: "Engineer",
        stage: :engineer,
        model: "claude-opus-5-5",
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
end
