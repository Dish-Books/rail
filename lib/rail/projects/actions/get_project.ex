defmodule Rail.Projects.Actions.GetProject do
  @moduledoc false

  import Ecto.Query

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  def get_project(id) when is_binary(id) do
    case Repo.one(from p in Project, where: p.id == ^id, preload: :linear_workspace) do
      %Project{} = project -> {:ok, project}
      nil -> {:error, :not_found}
    end
  end
end
