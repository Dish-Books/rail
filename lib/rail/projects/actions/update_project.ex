defmodule Rail.Projects.Actions.UpdateProject do
  @moduledoc false

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  def update_project(_scope, %Project{} = project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end
end
