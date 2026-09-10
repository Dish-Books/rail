defmodule Rail.Roles.Actions.GetRole do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  def get_role(_scope, id) do
    do_get_role(id)
  end

  def get_role!(%Scope{system: true}, id) when is_binary(id) do
    Repo.get!(Role, id)
  end

  def get_role!(%Scope{user: %{}}, id) when is_binary(id) do
    Repo.get!(Role, id)
  end

  def get_role!(_scope, _id) do
    raise Ecto.NoResultsError, queryable: Role
  end

  defp do_get_role(id) do
    case Repo.get(Role, id) do
      %Role{} = role -> {:ok, role}
      nil -> {:error, :not_found}
    end
  end
end
