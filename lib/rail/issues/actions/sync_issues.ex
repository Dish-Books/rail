defmodule Rail.Issues.Actions.SyncIssues do
  @moduledoc false

  alias Rail.Issues.Workers.LinearSync

  @doc """
  Queues a pull of `project`'s issues from Linear; the worker pages through them.
  Every page carries the time it was asked for, which the last page prunes against.
  """
  def sync_issues(project) do
    %{project_id: project.id, started_at: DateTime.utc_now()}
    |> LinearSync.new()
    |> Oban.insert()
  end
end
