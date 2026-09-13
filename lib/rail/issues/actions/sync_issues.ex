defmodule Rail.Issues.Actions.SyncIssues do
  @moduledoc false

  alias Rail.Issues.Workers.SyncProjectIssues

  @doc """
  Queues a pull of `project`'s issues from Linear; the worker pages through them.
  """
  def sync_issues(project) do
    %{project_id: project.id}
    |> SyncProjectIssues.new()
    |> Oban.insert()
  end
end
