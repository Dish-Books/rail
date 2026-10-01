defmodule Rail.Roles.Actions.ListRoles do
  @moduledoc false

  import Ecto.Query
  import Rail.Roles.Utils.LoadPrompts

  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  def list_roles(project_id) do
    roles =
      Repo.all(
        from(r in Role,
          where: r.project_id == ^project_id,
          order_by: [asc: r.position, asc: r.inserted_at],
          preload: [:backend, :project]
        )
      )

    case roles do
      [%Role{project: project} | _rest] -> load_prompts(project, roles)
      [] -> []
    end
  end
end
