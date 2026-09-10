defmodule Rail.Roles.Actions.ApplyImprovedInstructions do
  @moduledoc false

  alias Rail.Roles.Schemas.Role

  def apply_improved_instructions(scope, %Role{} = role, proposed_instructions) when is_binary(proposed_instructions) do
    Rail.Roles.update_role(scope, role, %{system_prompt: proposed_instructions})
  end
end
