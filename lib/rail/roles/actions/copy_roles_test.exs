defmodule Rail.Roles.Actions.CopyRolesTest do
  use Rail.DataCase, async: true

  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  test "copies roles from source project to target project" do
    scope = Scope.for_user(%{admin: true})
    source = create_test_project()
    target = create_test_project()

    create_test_role(
      project_id: source.id,
      stage: :product,
      name: "Source PM",
      system_prompt: "Source PM prompt"
    )

    create_test_role(
      project_id: source.id,
      stage: :engineer,
      name: "Source Engineer",
      system_prompt: "Source Engineer prompt"
    )

    assert {:ok, [%Role{name: "Source PM"}, %Role{name: "Source Engineer"}]} =
             Roles.copy_roles(scope, target, source.id)

    target_roles = Roles.list_roles(scope, target.id)
    assert length(target_roles) == 2
    assert Enum.any?(target_roles, &(&1.name == "Source PM" && &1.stage == :product))
    assert Enum.any?(target_roles, &(&1.name == "Source Engineer" && &1.stage == :engineer))
  end

  test "copies roles using target project ID string" do
    scope = Scope.for_system()
    source = create_test_project()
    target = create_test_project()

    create_test_role(project_id: source.id, name: "Source Role")

    assert {:ok, [%Role{name: "Source Role"}]} =
             Roles.copy_roles(scope, target.id, source.id)
  end

  test "unbinds existing stage in target project when copied role shares the stage" do
    scope = Scope.for_user(%{admin: true})
    source = create_test_project()
    target = create_test_project()

    old_target_role =
      create_test_role(
        project_id: target.id,
        stage: :engineer,
        name: "Old Target Engineer"
      )

    create_test_role(
      project_id: source.id,
      stage: :engineer,
      name: "New Copied Engineer"
    )

    assert {:ok, [%Role{name: "New Copied Engineer", stage: :engineer}]} =
             Roles.copy_roles(scope, target, source.id)

    assert {:ok, %Role{stage: nil}} = Roles.get_role(scope, old_target_role.id)
    assert {:ok, %Role{name: "New Copied Engineer"}} = Roles.role_for_stage(target.id, :engineer)
  end

  test "replaces all existing roles in target when replace_all: true" do
    scope = Scope.for_user(%{admin: true})
    source = create_test_project()
    target = create_test_project()

    create_test_role(project_id: target.id, name: "Existing Target Role")
    create_test_role(project_id: source.id, name: "Copied Source Role")

    assert {:ok, [%Role{name: "Copied Source Role"}]} =
             Roles.copy_roles(scope, target, source.id, replace_all: true)

    roles = Roles.list_roles(scope, target.id)
    assert [%Role{name: "Copied Source Role"}] = roles
  end

  test "returns error when target project is nil" do
    scope = Scope.for_user(%{admin: true})
    source = create_test_project()

    assert {:error, :target_project_not_found} = Roles.copy_roles(scope, nil, source.id)
  end

  test "returns not authorized for non-admin scope" do
    scope = Scope.for_user(%{admin: false})
    source = create_test_project()
    target = create_test_project()

    assert {:error, :not_authorized} = Roles.copy_roles(scope, target, source.id)
  end

  test "rolls back when target project id does not exist in db" do
    scope = Scope.for_user(%{admin: true})
    source = create_test_project()
    create_test_role(project_id: source.id, name: "Source PM")

    assert {:error, changeset} = Roles.copy_roles(scope, "prj_000000000000000000000000", source.id)
    assert %{project_id: ["does not exist"]} = errors_on(changeset)
  end
end
