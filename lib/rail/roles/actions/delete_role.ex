defmodule Rail.Roles.Actions.DeleteRole do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope
  alias Rail.Users

  def delete_role(scope, %Role{} = role) do
    if Scope.admin?(scope) or Users.can?(scope, :manage_roles) do
      Repo.delete(role)
    else
      {:error, :not_authorized}
    end
  end
end
