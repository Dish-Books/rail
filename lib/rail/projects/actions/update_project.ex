defmodule Rail.Projects.Actions.UpdateProject do
  @moduledoc false

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  def update_project(_scope, %Project{} = project, attrs) do
    with {:ok, project} <- project |> Project.changeset(attrs) |> Repo.update() do
      {:ok, Repo.preload(project, :linear_workspace, force: true)}
    end
  end
end
