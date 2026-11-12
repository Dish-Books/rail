defmodule Rail.Issues.Actions.MoveToLocalTracker do
  @moduledoc false

  alias Rail.Issues.Workers.MoveToLocalTracker
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope

  @doc """
  Queues the move of a Linear project's tickets into Rail, and broadcasts `{:project_changed, project_id}` on
  `"projects"`. While a move is queued or running, returns that move's job and starts none.
  """
  def move_to_local_tracker(%Scope{}, %Project{id: project_id}) do
    # Read again, since a page loaded before another tab's move still holds the project on Linear.
    case Projects.get_project(project_id) do
      {:ok, %Project{tracker: :linear}} ->
        with {:ok, job} <- %{project_id: project_id} |> MoveToLocalTracker.new() |> Oban.insert() do
          Phoenix.PubSub.broadcast(Rail.PubSub, "projects", {:project_changed, project_id})
          {:ok, job}
        end

      {:ok, %Project{}} ->
        {:error, :not_on_linear}

      {:error, :not_found} = error ->
        error
    end
  end
end
