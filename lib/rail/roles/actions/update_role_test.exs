defmodule Rail.Roles.Actions.UpdateRoleTest do
  use Rail.DataCase, async: true

  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  test "updates role attributes with admin scope" do
    scope = Scope.for_user(%{admin: true})
    role = create_test_role(name: "Old Name", system_prompt: "Old prompt")

    attrs = %{
      name: "New Name",
      system_prompt: "New prompt",
      position: 5,
      max_concurrent: 3
    }

    assert {:ok, %Role{name: "New Name", system_prompt: "New prompt", position: 5, max_concurrent: 3}} =
             Roles.update_role(scope, role, attrs)
  end

  test "updates role attributes with system scope" do
    scope = Scope.for_system()
    role = create_test_role()

    assert {:ok, %Role{model: "claude-next"}} =
             Roles.update_role(scope, role, %{model: "claude-next"})
  end

  test "returns validation errors on invalid updates" do
    scope = Scope.for_user(%{admin: true})
    role = create_test_role()

    assert {:error, changeset} = Roles.update_role(scope, role, %{max_concurrent: 0, model: nil})

    assert %{
             max_concurrent: ["must be greater than or equal to 1"],
             model: ["can't be blank"]
           } = errors_on(changeset)
  end

  test "returns not authorized for non-admin scope" do
    scope = Scope.for_user(%{admin: false})
    role = create_test_role()

    assert {:error, :not_authorized} = Roles.update_role(scope, role, %{name: "Updated"})
  end

  test "returns not authorized for nil scope" do
    role = create_test_role()
    assert {:error, :not_authorized} = Roles.update_role(nil, role, %{name: "Updated"})
  end
end
