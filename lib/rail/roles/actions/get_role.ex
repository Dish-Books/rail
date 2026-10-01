defmodule Rail.Roles.Actions.GetRole do
  @moduledoc false

  import Rail.Roles.Utils.LoadPrompts

  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  # The backend comes along because a role is only ever useful with the executable it
  # runs: the spawn path reads it straight off `role.backend`. The prompt is the one
  # its project's repo has merged, where it has one.
  def get_role(by) do
    case Repo.get_by(Role, by) do
      %Role{} = role ->
        role = Repo.preload(role, [:backend, :project])
        [role] = load_prompts(role.project, [role])
        {:ok, role}

      nil ->
        {:error, :role_not_found}
    end
  end
end
