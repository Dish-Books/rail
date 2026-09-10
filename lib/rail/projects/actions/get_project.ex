defmodule Rail.Projects.Actions.GetProject do
  @moduledoc false

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  def get_project(_scope, id) when is_binary(id) do
    do_get_project(id)
  end

  def get_project!(%Scope{system: true}, id) when is_binary(id) do
    Repo.get!(Project, id)
  end

  def get_project!(%Scope{user: %{}}, id) when is_binary(id) do
    Repo.get!(Project, id)
  end

  def get_project!(_scope, id) when is_binary(id) do
    raise Ecto.NoResultsError, queryable: Project
  end

  defp do_get_project(id) do
    case Repo.get(Project, id) do
      %Project{} = project -> {:ok, project}
      nil -> {:error, :not_found}
    end
  end
end
