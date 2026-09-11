defmodule Rail.Roles.Actions.ListRoles do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  def list_roles(%Scope{system: true}, project_id) when is_binary(project_id) do
    fetch_roles(project_id)
  end

  def list_roles(%Scope{user: %{}}, project_id) when is_binary(project_id) do
    fetch_roles(project_id)
  end

  def list_roles(_scope, _project_id), do: []

  defp fetch_roles(project_id) do
    Repo.all(
      from(r in Role,
        where: r.project_id == ^project_id,
        order_by: [asc: r.position, asc: r.inserted_at],
        preload: :backend
      )
    )
  end
end
