defmodule Rail.Roles.Actions.ListRolesTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  setup do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "List Roles Project",
        github_repo: "org/list-roles",
        github_installation_id: 4201,
        linear_team_id: "team_list_roles",
        linear_team_key: "LR1",
        clone_path: "/tmp/repos/list-roles"
      })

    %{project: project}
  end

  test "lists roles for a project ordered by position and inserted_at", %{project: project} do
    scope = Scope.for_user(%{admin: true})

    {:ok, %Role{id: role1_id}} =
      Roles.create_role(system_scope(), project, %{
        name: "Second Role",
        position: 2,
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent."
      })

    {:ok, %Role{id: role2_id}} =
      Roles.create_role(system_scope(), project, %{
        name: "First Role",
        position: 1,
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent."
      })

    {:ok, %Role{id: role3_id}} =
      Roles.create_role(system_scope(), project, %{
        name: "Third Role",
        position: 2,
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent."
      })

    assert [%Role{id: ^role2_id}, %Role{id: ^role1_id}, %Role{id: ^role3_id}] =
             Roles.list_roles(scope, project.id)
  end

  test "lists roles with normal authenticated user scope", %{project: project} do
    scope = Scope.for_user(%{admin: false})

    {:ok, %Role{id: role_id}} =
      Roles.create_role(system_scope(), project, %{
        name: "Engineer",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent."
      })

    assert [%Role{id: ^role_id}] = Roles.list_roles(scope, project.id)
  end

  test "lists roles with system scope", %{project: project} do
    scope = Scope.for_system()

    {:ok, %Role{id: role_id}} =
      Roles.create_role(scope, project, %{
        name: "Engineer",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent."
      })

    assert [%Role{id: ^role_id}] = Roles.list_roles(scope, project.id)
  end

  test "filters roles strictly to the requested project", %{project: project_a} do
    scope = Scope.for_system()

    {:ok, project_b} =
      Projects.create_project(scope, %{
        name: "Other List Roles Project",
        github_repo: "org/list-roles-other",
        github_installation_id: 4202,
        linear_team_id: "team_list_roles_other",
        linear_team_key: "LR2",
        clone_path: "/tmp/repos/list-roles-other"
      })

    {:ok, %Role{id: role_a_id}} =
      Roles.create_role(scope, project_a, %{
        name: "Role in Project A",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent."
      })

    {:ok, _role_b} =
      Roles.create_role(scope, project_b, %{
        name: "Role in Project B",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent."
      })

    assert [%Role{id: ^role_a_id}] = Roles.list_roles(scope, project_a.id)
  end

  test "returns empty list for unauthenticated or nil scope", %{project: project} do
    {:ok, _role} =
      Roles.create_role(system_scope(), project, %{
        name: "Engineer",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent."
      })

    assert Roles.list_roles(nil, project.id) == []
    assert Roles.list_roles(%Scope{user: nil, system: false}, project.id) == []
  end
end
