defmodule Rail.Roles.Actions.UpdateRole do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  # Reloads the backend, since an update may have pointed the role at a different one.
  def update_role(_scope, %Role{} = role, attrs) do
    case role |> Role.changeset(attrs) |> Repo.update() do
      {:ok, updated} -> {:ok, Repo.preload(updated, :backend, force: true)}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
