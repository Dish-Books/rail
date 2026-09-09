defmodule Rail.Roles.Actions.UpdateRole do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope
  alias Rail.Users

  def update_role(scope, %Role{} = role, attrs) do
    if Scope.admin?(scope) or Users.can?(scope, :manage_roles) do
      role
      |> Role.changeset(attrs)
      |> Repo.update()
    else
      {:error, :not_authorized}
    end
  end
end
