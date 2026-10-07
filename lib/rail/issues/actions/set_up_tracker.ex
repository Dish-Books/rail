defmodule Rail.Issues.Actions.SetUpTracker do
  @moduledoc false

  alias Rail.Issues.Tracker
  alias Rail.Projects.Schemas.Project

  @doc """
  Prepares `project`'s tracker once the project is saved, such as the labels it needs.
  """
  def set_up_tracker(%Project{} = project), do: Tracker.tracker(project).set_up_project(project)
end
