defmodule Rail.Roles.Actions.ListRolesTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  setup do
    {:ok, backend} =
      Rail.Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "List Roles Project",
        github_repo: "org/list-roles",
        github_installation_id: 4201,
        linear_team_id: "team_list_roles",
        linear_team_key: "LR1",
        default_branch: "main",
        clone_path: "/tmp/repos/list-roles"
      })

    %{backend: backend, project: project}
  end

  test "lists roles for a project ordered by position and inserted_at", %{backend: backend, project: project} do
    {:ok, %Role{id: role1_id}} =
      Roles.create_role(system_scope(), project, %{
        backend_id: backend.id,
        name: "Second Role",
        position: 2,
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent."
      })

    {:ok, %Role{id: role2_id}} =
      Roles.create_role(system_scope(), project, %{
        backend_id: backend.id,
        name: "First Role",
        position: 1,
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent."
      })

    {:ok, %Role{id: role3_id}} =
      Roles.create_role(system_scope(), project, %{
        backend_id: backend.id,
        name: "Third Role",
        position: 2,
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent."
      })

    assert [%Role{id: ^role2_id}, %Role{id: ^role1_id}, %Role{id: ^role3_id}] =
             Roles.list_roles(project.id)
  end

  test "lists roles with system scope", %{backend: backend, project: project} do
    scope = Scope.for_system()

    {:ok, %Role{id: role_id}} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        name: "Engineer",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent."
      })

    assert [%Role{id: ^role_id}] = Roles.list_roles(project.id)
  end

  test "filters roles strictly to the requested project", %{backend: backend, project: project_a} do
    scope = Scope.for_system()

    {:ok, project_b} =
      Projects.create_project(scope, %{
        name: "Other List Roles Project",
        github_repo: "org/list-roles-other",
        github_installation_id: 4202,
        linear_team_id: "team_list_roles_other",
        linear_team_key: "LR2",
        default_branch: "main",
        clone_path: "/tmp/repos/list-roles-other"
      })

    {:ok, %Role{id: role_a_id}} =
      Roles.create_role(scope, project_a, %{
        backend_id: backend.id,
        name: "Role in Project A",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent."
      })

    {:ok, _role_b} =
      Roles.create_role(scope, project_b, %{
        backend_id: backend.id,
        name: "Role in Project B",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent."
      })

    assert [%Role{id: ^role_a_id}] = Roles.list_roles(project_a.id)
  end
end
