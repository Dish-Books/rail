defmodule Rail.Roles.Actions.DeleteRoleTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  setup do
    scope = system_scope()

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Delete Role Project",
        github_repo: "org/delete-role",
        github_installation_id: 4104,
        linear_team_id: "team_delete_role",
        linear_team_key: "DLR",
        default_branch: "main",
        clone_path: "/tmp/repos/delete-role"
      })

    {:ok, role} =
      Roles.create_role(scope, project, %{
        name: "Engineer",
        stage: :engineer,
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert engineer."
      })

    %{project: project, role: role}
  end

  test "deletes role with admin scope", %{role: %Role{id: role_id} = role} do
    scope = Scope.for_user(%{admin: true})

    assert {:ok, %Role{id: ^role_id}} = Roles.delete_role(scope, role)
    assert Roles.get_role(id: role.id) == {:error, :role_not_found}
  end

  test "deletes role with system scope", %{role: %Role{id: role_id} = role} do
    scope = Scope.for_system()

    assert {:ok, %Role{id: ^role_id}} = Roles.delete_role(scope, role)
  end

  test "returns not authorized for non-admin scope", %{role: %Role{id: role_id} = role} do
    scope = Scope.for_user(%{admin: false})

    assert {:error, :not_authorized} = Roles.delete_role(scope, role)
    assert {:ok, %Role{id: ^role_id}} = Roles.get_role(id: role.id)
  end

  test "returns not authorized for nil scope", %{role: role} do
    assert {:error, :not_authorized} = Roles.delete_role(nil, role)
  end
end
