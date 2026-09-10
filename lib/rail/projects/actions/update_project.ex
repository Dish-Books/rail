defmodule Rail.Projects.Actions.UpdateProject do
  @moduledoc false

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  def update_project(_scope, %Project{} = project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  def update_project(scope, id, attrs) when is_binary(id) do
    case Repo.get(Project, id) do
      %Project{} = project -> update_project(scope, project, attrs)
      nil -> {:error, :not_found}
    end
  end
end
