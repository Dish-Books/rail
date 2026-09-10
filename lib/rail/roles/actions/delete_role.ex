defmodule Rail.Roles.Actions.DeleteRole do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  def delete_role(_scope, %Role{} = role) do
    Repo.delete(role)
  end
end
