defmodule Rail.Projects.Actions.ListProjects do
  @moduledoc false

  import Ecto.Query

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  def list_projects(%Scope{system: true}) do
    fetch_projects()
  end

  def list_projects(%Scope{user: %{}}) do
    fetch_projects()
  end

  def list_projects(_scope), do: []

  defp fetch_projects do
    Repo.all(from p in Project, order_by: [asc: p.name, asc: p.inserted_at])
  end
end
