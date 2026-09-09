defmodule Rail.Roles.Actions.GetRoleTest do
  use Rail.DataCase, async: true

  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  test "returns role for authenticated user" do
    scope = Scope.for_user(%{admin: false})
    %Role{id: role_id} = role = create_test_role()

    assert {:ok, %Role{id: ^role_id}} = Roles.get_role(scope, role.id)
  end

  test "returns role for system scope" do
    scope = Scope.for_system()
    %Role{id: role_id} = role = create_test_role()

    assert {:ok, %Role{id: ^role_id}} = Roles.get_role(scope, role.id)
  end

  test "returns not found error when role does not exist" do
    scope = Scope.for_system()
    assert {:error, :not_found} = Roles.get_role(scope, "rol_000000000000000000000000")
  end

  test "returns not authorized error for nil or invalid scope" do
    role = create_test_role()
    assert {:error, :not_authorized} = Roles.get_role(nil, role.id)
    assert {:error, :not_authorized} = Roles.get_role(%Scope{user: nil, system: false}, role.id)
  end

  test "get_role! returns role for authenticated scope" do
    scope = Scope.for_system()
    %Role{id: role_id} = role = create_test_role()

    assert %Role{id: ^role_id} = Roles.get_role!(scope, role.id)
  end

  test "get_role! raises Ecto.NoResultsError when role does not exist" do
    scope = Scope.for_system()

    assert_raise Ecto.NoResultsError, fn ->
      Roles.get_role!(scope, "rol_000000000000000000000000")
    end
  end

  test "get_role! raises Ecto.NoResultsError when scope is unauthorized" do
    role = create_test_role()

    assert_raise Ecto.NoResultsError, fn ->
      Roles.get_role!(nil, role.id)
    end
  end
end
