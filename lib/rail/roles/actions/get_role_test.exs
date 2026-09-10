defmodule Rail.Roles.Actions.GetRoleTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  setup do
    scope = system_scope()

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Get Role Project",
        github_repo: "org/get-role",
        github_installation_id: 4102,
        linear_team_id: "team_get_role",
        linear_team_key: "GTR",
        clone_path: "/tmp/repos/get-role"
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

  test "returns role for authenticated user", %{role: %Role{id: role_id} = role} do
    scope = Scope.for_user(%{admin: false})

    assert {:ok, %Role{id: ^role_id}} = Roles.get_role(scope, role.id)
  end

  test "returns role for system scope", %{role: %Role{id: role_id} = role} do
    scope = Scope.for_system()

    assert {:ok, %Role{id: ^role_id}} = Roles.get_role(scope, role.id)
  end

  test "returns not found error when role does not exist" do
    scope = Scope.for_system()
    assert {:error, :not_found} = Roles.get_role(scope, "rol_000000000000000000000000")
  end

  test "returns not authorized error for nil or invalid scope", %{role: role} do
    assert {:error, :not_authorized} = Roles.get_role(nil, role.id)
    assert {:error, :not_authorized} = Roles.get_role(%Scope{user: nil, system: false}, role.id)
  end

  test "get_role! returns role for authenticated scope", %{role: %Role{id: role_id} = role} do
    scope = Scope.for_system()

    assert %Role{id: ^role_id} = Roles.get_role!(scope, role.id)
  end

  test "get_role! raises Ecto.NoResultsError when role does not exist" do
    scope = Scope.for_system()

    assert_raise Ecto.NoResultsError, fn ->
      Roles.get_role!(scope, "rol_000000000000000000000000")
    end
  end

  test "get_role! raises Ecto.NoResultsError when scope is unauthorized", %{role: role} do
    assert_raise Ecto.NoResultsError, fn ->
      Roles.get_role!(nil, role.id)
    end
  end
end
