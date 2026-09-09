defmodule Rail.Roles.Actions.ApplyImprovedInstructions do
  @moduledoc false

  alias Rail.Roles.Schemas.Role
  alias Rail.Scope
  alias Rail.Users

  def apply_improved_instructions(scope, %Role{} = role, proposed_instructions) when is_binary(proposed_instructions) do
    if Scope.admin?(scope) or Users.can?(scope, :manage_roles) do
      Rail.Roles.update_role(scope, role, %{system_prompt: proposed_instructions})
    else
      {:error, :not_authorized}
    end
  end
end
