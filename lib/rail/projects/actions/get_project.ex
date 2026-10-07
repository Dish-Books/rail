defmodule Rail.Projects.Actions.GetProject do
  @moduledoc false

  import Ecto.Query

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  def get_project(id) when is_binary(id), do: get_project(id: id)

  # By `id`, or by `github_repo` for a GitHub webhook naming its repository.
  def get_project([{field, value}]) when field in [:id, :github_repo] and is_binary(value) do
    case Repo.one(
           from p in Project, where: field(p, ^field) == ^value, preload: [:linear_workspace, :learnings_slack_workspace]
         ) do
      %Project{} = project -> {:ok, project}
      nil -> {:error, :not_found}
    end
  end
end
