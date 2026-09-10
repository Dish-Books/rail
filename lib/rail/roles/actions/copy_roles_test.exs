defmodule Rail.Roles.Actions.CopyRolesTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  setup do
    scope = system_scope()

    {:ok, source} =
      Projects.create_project(scope, %{
        name: "Copy Roles Source",
        github_repo: "org/copy-roles-source",
        github_installation_id: 4301,
        linear_team_id: "team_copy_source",
        linear_team_key: "CPS",
        clone_path: "/tmp/repos/copy-roles-source"
      })

    {:ok, target} =
      Projects.create_project(scope, %{
        name: "Copy Roles Target",
        github_repo: "org/copy-roles-target",
        github_installation_id: 4302,
        linear_team_id: "team_copy_target",
        linear_team_key: "CPT",
        clone_path: "/tmp/repos/copy-roles-target"
      })

    %{source: source, target: target}
  end

  test "copies roles from source project to target project", %{source: source, target: target} do
    scope = Scope.for_user(%{admin: true})

    {:ok, _source_pm} =
      Roles.create_role(system_scope(), source, %{
        stage: :product,
        name: "Source PM",
        model: "claude-3-7-sonnet",
        system_prompt: "Source PM prompt"
      })

    {:ok, _source_engineer} =
      Roles.create_role(system_scope(), source, %{
        stage: :engineer,
        name: "Source Engineer",
        model: "claude-3-7-sonnet",
        system_prompt: "Source Engineer prompt"
      })

    assert {:ok, [%Role{name: "Source PM"}, %Role{name: "Source Engineer"}]} =
             Roles.copy_roles(scope, target, source.id)

    target_roles = Roles.list_roles(scope, target.id)
    assert length(target_roles) == 2
    assert Enum.any?(target_roles, &(&1.name == "Source PM" && &1.stage == :product))
    assert Enum.any?(target_roles, &(&1.name == "Source Engineer" && &1.stage == :engineer))
  end

  test "copies roles using target project ID string", %{source: source, target: target} do
    scope = Scope.for_system()

    {:ok, _source_role} =
      Roles.create_role(scope, source, %{
        name: "Source Role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent."
      })

    assert {:ok, [%Role{name: "Source Role"}]} =
             Roles.copy_roles(scope, target.id, source.id)
  end

  test "unbinds existing stage in target project when copied role shares the stage", %{source: source, target: target} do
    scope = Scope.for_user(%{admin: true})

    {:ok, old_target_role} =
      Roles.create_role(system_scope(), target, %{
        stage: :engineer,
        name: "Old Target Engineer",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert engineer."
      })

    {:ok, _new_engineer} =
      Roles.create_role(system_scope(), source, %{
        stage: :engineer,
        name: "New Copied Engineer",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert engineer."
      })

    assert {:ok, [%Role{name: "New Copied Engineer", stage: :engineer}]} =
             Roles.copy_roles(scope, target, source.id)

    assert {:ok, %Role{stage: nil}} = Roles.get_role(scope, old_target_role.id)
    assert {:ok, %Role{name: "New Copied Engineer"}} = Roles.role_for_stage(target.id, :engineer)
  end

  test "replaces all existing roles in target when replace_all: true", %{source: source, target: target} do
    scope = Scope.for_user(%{admin: true})

    {:ok, _existing} =
      Roles.create_role(system_scope(), target, %{
        name: "Existing Target Role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent."
      })

    {:ok, _copied} =
      Roles.create_role(system_scope(), source, %{
        name: "Copied Source Role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent."
      })

    assert {:ok, [%Role{name: "Copied Source Role"}]} =
             Roles.copy_roles(scope, target, source.id, replace_all: true)

    roles = Roles.list_roles(scope, target.id)
    assert [%Role{name: "Copied Source Role"}] = roles
  end

  test "returns error when target project is nil", %{source: source} do
    scope = Scope.for_user(%{admin: true})

    assert {:error, :target_project_not_found} = Roles.copy_roles(scope, nil, source.id)
  end

  test "returns not authorized for non-admin scope", %{source: source, target: target} do
    scope = Scope.for_user(%{admin: false})

    assert {:error, :not_authorized} = Roles.copy_roles(scope, target, source.id)
  end

  test "rolls back when target project id does not exist in db", %{source: source} do
    scope = Scope.for_user(%{admin: true})

    {:ok, _source_pm} =
      Roles.create_role(scope, source, %{
        name: "Source PM",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent."
      })

    assert {:error, changeset} = Roles.copy_roles(scope, "prj_000000000000000000000000", source.id)
    assert %{project_id: ["does not exist"]} = errors_on(changeset)
  end
end
