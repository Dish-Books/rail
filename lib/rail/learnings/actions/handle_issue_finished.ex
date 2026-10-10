defmodule Rail.Learnings.Actions.HandleIssueFinished do
  @moduledoc """
  Queues what Learnings does when an issue finishes, and nothing more, so the
  tracker's webhook or poll goes on without waiting on it.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings.Workers.IssueFinished

  @doc """
  Inserts an `IssueFinished` job for `issue`; one already waiting is reused. Returns `{:ok, job}`.
  """
  def handle_issue_finished(%Issue{id: issue_id}) do
    %{issue_id: issue_id} |> IssueFinished.new() |> Oban.insert()
  end
end
