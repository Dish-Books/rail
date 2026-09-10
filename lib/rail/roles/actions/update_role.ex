defmodule Rail.Roles.Actions.UpdateRole do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  def update_role(_scope, %Role{} = role, attrs) do
    role
    |> Role.changeset(attrs)
    |> Repo.update()
  end
end
