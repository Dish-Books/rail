defmodule Rail.Issues.Actions.GetStatuses do
  @moduledoc false

  alias Rail.Issues.Tracker
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope

  @doc """
  Asks `project`'s tracker for the statuses a person can pick, as `Rail.Issues.Tracker.get_statuses/1` describes.
  """
  def get_statuses(%Scope{} = scope, %Project{id: project_id} = project) do
    if Scope.can_access_project?(scope, project_id),
      do: Tracker.tracker(project).get_statuses(project),
      else: {:error, :not_found}
  end
end
