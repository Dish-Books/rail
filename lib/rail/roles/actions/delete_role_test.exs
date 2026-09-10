defmodule Rail.Roles.Actions.DeleteRoleTest do
  use Rail.DataCase, async: true

  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  test "deletes role with admin scope" do
    scope = Scope.for_user(%{admin: true})
    %Role{id: role_id} = role = create_test_role()

    assert {:ok, %Role{id: ^role_id}} = Roles.delete_role(scope, role)
    assert Roles.get_role(scope, role.id) == {:error, :not_found}
  end

  test "deletes role with system scope" do
    scope = Scope.for_system()
    %Role{id: role_id} = role = create_test_role()

    assert {:ok, %Role{id: ^role_id}} = Roles.delete_role(scope, role)
  end

  test "returns not authorized for non-admin scope" do
    scope = Scope.for_user(%{admin: false})
    %Role{id: role_id} = role = create_test_role()

    assert {:error, :not_authorized} = Roles.delete_role(scope, role)
    assert {:ok, %Role{id: ^role_id}} = Roles.get_role(scope, role.id)
  end

  test "returns not authorized for nil scope" do
    role = create_test_role()
    assert {:error, :not_authorized} = Roles.delete_role(nil, role)
  end
end
