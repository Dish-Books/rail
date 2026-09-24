defmodule Rail.Projects.Actions.ListLinearWorkspaces do
  @moduledoc false

  import Ecto.Query

  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Repo

  def list_linear_workspaces do
    Repo.all(from w in LinearWorkspace, order_by: [asc: w.name, asc: w.inserted_at], preload: :projects)
  end
end
