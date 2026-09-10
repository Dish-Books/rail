defmodule Rail.Roles.Actions.ListRolesTest do
  use Rail.DataCase, async: true

  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  test "lists roles for a project ordered by position and inserted_at" do
    scope = Scope.for_user(%{admin: true})
    project = create_test_project()

    %Role{id: role1_id} = create_test_role(project_id: project.id, name: "Second Role", position: 2)
    %Role{id: role2_id} = create_test_role(project_id: project.id, name: "First Role", position: 1)
    %Role{id: role3_id} = create_test_role(project_id: project.id, name: "Third Role", position: 2)

    assert [%Role{id: ^role2_id}, %Role{id: ^role1_id}, %Role{id: ^role3_id}] =
             Roles.list_roles(scope, project.id)
  end

  test "lists roles with normal authenticated user scope" do
    scope = Scope.for_user(%{admin: false})
    project = create_test_project()
    %Role{id: role_id} = create_test_role(project_id: project.id)

    assert [%Role{id: ^role_id}] = Roles.list_roles(scope, project.id)
  end

  test "lists roles with system scope" do
    scope = Scope.for_system()
    project = create_test_project()
    %Role{id: role_id} = create_test_role(project_id: project.id)

    assert [%Role{id: ^role_id}] = Roles.list_roles(scope, project.id)
  end

  test "filters roles strictly to the requested project" do
    scope = Scope.for_system()
    project_a = create_test_project()
    project_b = create_test_project()

    %Role{id: role_a_id} = create_test_role(project_id: project_a.id, name: "Role in Project A")
    _role_b = create_test_role(project_id: project_b.id, name: "Role in Project B")

    assert [%Role{id: ^role_a_id}] = Roles.list_roles(scope, project_a.id)
  end

  test "returns empty list for unauthenticated or nil scope" do
    project = create_test_project()
    create_test_role(project_id: project.id)

    assert Roles.list_roles(nil, project.id) == []
    assert Roles.list_roles(%Scope{user: nil, system: false}, project.id) == []
  end
end
