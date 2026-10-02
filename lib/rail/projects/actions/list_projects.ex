defmodule Rail.Projects.Actions.ListProjects do
  @moduledoc false

  import Ecto.Query

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  def list_projects(scope) do
    Project
    |> order_by([p], asc: p.name, asc: p.inserted_at)
    |> preload(:linear_workspace)
    |> then(&if(ids = Scope.project_ids(scope), do: where(&1, [p], p.id in ^ids), else: &1))
    |> Repo.all()
  end
end
