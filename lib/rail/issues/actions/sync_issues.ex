defmodule Rail.Issues.Actions.SyncIssues do
  @moduledoc false

  alias Rail.Issues.Tracker
  alias Rail.Projects.Schemas.Project

  @doc """
  Queues a full pull of `project`'s issues from its tracker; the worker pages through them.
  """
  def sync_issues(%Project{} = project), do: Tracker.tracker(project).sync_issues(project)
end
