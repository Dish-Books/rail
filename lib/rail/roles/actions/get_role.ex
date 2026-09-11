defmodule Rail.Roles.Actions.GetRole do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  def get_role(by) do
    case Repo.get_by(Role, by) do
      %Role{} = role -> {:ok, role}
      nil -> {:error, :role_not_found}
    end
  end
end
