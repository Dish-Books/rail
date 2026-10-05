defmodule Rail.Roles.Actions.ListRolesTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  setup do
    project =
      %Project{}
      |> Project.changeset(%{
        name: "List Roles Project",
        github_repo: "org/list-roles",
        github_installation_id: 4201,
        linear_team_key: "LR1",
        default_branch: "main",
        clone_path: "/tmp/repos/list-roles"
      })
      |> Repo.insert!()

    %{project: project}
  end

  test "lists roles for a project ordered by position and inserted_at", %{project: project} do
    {:ok, %Role{id: role1_id}} =
      Roles.create_role(system_scope(), project, %{
        cli: :claude,
        name: "Second Role",
        position: 2,
        model: "claude-opus-5-5",
        system_prompt: "You are an expert agent."
      })

    {:ok, %Role{id: role2_id}} =
      Roles.create_role(system_scope(), project, %{
        cli: :claude,
        name: "First Role",
        position: 1,
        model: "claude-opus-5-5",
        system_prompt: "You are an expert agent."
      })

    {:ok, %Role{id: role3_id}} =
      Roles.create_role(system_scope(), project, %{
        cli: :claude,
        name: "Third Role",
        position: 2,
        model: "claude-opus-5-5",
        system_prompt: "You are an expert agent."
      })

    assert [%Role{id: ^role2_id}, %Role{id: ^role1_id}, %Role{id: ^role3_id}] =
             Roles.list_roles(project.id)
  end

  test "lists roles with system scope", %{project: project} do
    scope = Scope.for_system()

    {:ok, %Role{id: role_id}} =
      Roles.create_role(scope, project, %{
        cli: :claude,
        name: "Engineer",
        model: "claude-opus-5-5",
        system_prompt: "You are an expert agent."
      })

    assert [%Role{id: ^role_id}] = Roles.list_roles(project.id)
  end

  test "filters roles strictly to the requested project", %{project: project_a} do
    scope = Scope.for_system()

    {:ok, project_b} =
      Projects.create_project(scope, %{
        name: "Other List Roles Project",
        github_repo: "org/list-roles-other",
        github_installation_id: 4202,
        linear_team_key: "LR2",
        default_branch: "main",
        clone_path: "/tmp/repos/list-roles-other"
      })

    {:ok, %Role{id: role_a_id}} =
      Roles.create_role(scope, project_a, %{
        cli: :claude,
        name: "Role in Project A",
        model: "claude-opus-5-5",
        system_prompt: "You are an expert agent."
      })

    {:ok, _role_b} =
      Roles.create_role(scope, project_b, %{
        cli: :claude,
        name: "Role in Project B",
        model: "claude-opus-5-5",
        system_prompt: "You are an expert agent."
      })

    assert [%Role{id: ^role_a_id}] = Roles.list_roles(project_a.id)
  end
end
