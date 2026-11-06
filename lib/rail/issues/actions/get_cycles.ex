defmodule Rail.Issues.Actions.GetCycles do
  @moduledoc false

  alias Rail.Issues.Tracker
  alias Rail.Projects.Schemas.Project

  @doc """
  Asks `project`'s tracker for its cycles and its team's statuses, as `Rail.Issues.Tracker.get_cycles/1` describes.
  """
  def get_cycles(%Project{} = project), do: Tracker.tracker(project).get_cycles(project)
end
