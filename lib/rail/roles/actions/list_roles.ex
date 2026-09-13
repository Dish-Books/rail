defmodule Rail.Roles.Actions.ListRoles do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  def list_roles(project_id) do
    Repo.all(
      from(r in Role,
        where: r.project_id == ^project_id,
        order_by: [asc: r.position, asc: r.inserted_at],
        preload: :backend
      )
    )
  end
end
