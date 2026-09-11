defmodule Rail.Roles.Actions.GetRole do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  # The backend comes along because a role is only ever useful with the executable it
  # runs: the spawn path reads it straight off `role.backend`.
  def get_role(by) do
    case Repo.get_by(Role, by) do
      %Role{} = role -> {:ok, Repo.preload(role, :backend)}
      nil -> {:error, :role_not_found}
    end
  end
end
