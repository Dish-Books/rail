defmodule Rail.Projects.Actions.CreateProject do
  @moduledoc false

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  def create_project(_scope, attrs) do
    with {:ok, project} <- %Project{} |> Project.changeset(attrs) |> Repo.insert() do
      {:ok, Repo.preload(project, :linear_workspace)}
    end
  end
end
