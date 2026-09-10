defmodule Rail.Roles.Actions.ApplyImprovedInstructionsTest do
  use Rail.DataCase, async: true

  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  test "applies improved instructions with admin scope" do
    scope = Scope.for_user(%{admin: true})
    role = create_test_role(system_prompt: "Old instructions")

    new_instructions = "Comprehensive revised system prompt instructions."

    assert {:ok, %Role{system_prompt: ^new_instructions}} =
             Roles.apply_improved_instructions(scope, role, new_instructions)

    assert {:ok, %Role{system_prompt: ^new_instructions}} = Roles.get_role(scope, role.id)
  end

  test "applies improved instructions with system scope" do
    scope = Scope.for_system()
    role = create_test_role(system_prompt: "Original")

    revised = "System approved prompt."

    assert {:ok, %Role{system_prompt: ^revised}} =
             Roles.apply_improved_instructions(scope, role, revised)
  end

  test "returns not authorized for non-admin scope" do
    scope = Scope.for_user(%{admin: false})
    role = create_test_role()

    assert {:error, :not_authorized} =
             Roles.apply_improved_instructions(scope, role, "Blocked instructions")
  end

  test "returns not authorized for nil scope" do
    role = create_test_role()

    assert {:error, :not_authorized} =
             Roles.apply_improved_instructions(nil, role, "Blocked instructions")
  end
end
