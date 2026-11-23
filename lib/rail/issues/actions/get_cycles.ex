defmodule Rail.Issues.Actions.GetCycles do
  @moduledoc false

  alias Rail.Issues.Tracker
  alias Rail.Projects.Schemas.Project

  @doc """
  `project`'s cycles and the statuses, as `Rail.Issues.Tracker.get_cycles/1` describes.
  """
  def get_cycles(%Project{} = project), do: Tracker.get_cycles(project)
end
