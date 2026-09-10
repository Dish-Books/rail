defmodule Rail.Projects.Actions.UpdateProject do
  @moduledoc false

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users

  def update_project(scope, %Project{} = project, attrs) do
    if authorized?(scope) do
      project
      |> Project.changeset(attrs)
      |> Repo.update()
    else
      {:error, :not_authorized}
    end
  end

  def update_project(scope, id, attrs) when is_binary(id) do
    case Repo.get(Project, id) do
      %Project{} = project -> update_project(scope, project, attrs)
      nil -> {:error, :not_found}
    end
  end

  defp authorized?(%Scope{} = scope) do
    Scope.admin?(scope) or Users.can?(scope, :update_project)
  end

  defp authorized?(_scope), do: false
end
