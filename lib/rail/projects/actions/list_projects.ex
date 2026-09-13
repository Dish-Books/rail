defmodule Rail.Projects.Actions.ListProjects do
  @moduledoc false

  import Ecto.Query

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  def list_projects do
    Repo.all(from p in Project, order_by: [asc: p.name, asc: p.inserted_at], preload: :linear_workspace)
  end
end
