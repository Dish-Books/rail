defmodule Rail.Projects.Actions.UpdateProject do
  @moduledoc false

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  Saves the project. `attrs` may carry `slack_channels`, the whole set the project triages: one sent with
  its `id` is updated in place and one left out is removed. Announced on `"projects"` for the pages showing it.
  """
  def update_project(_scope, %Project{} = project, attrs) do
    project = Repo.preload(project, :slack_channels, force: true)

    with {:ok, project} <- project |> Project.changeset(attrs) |> Repo.update() do
      Phoenix.PubSub.broadcast(Rail.PubSub, "projects", {:project_changed, project.id})
      {:ok, Repo.preload(project, [:linear_workspace, :learnings_slack_workspace], force: true)}
    end
  end
end
