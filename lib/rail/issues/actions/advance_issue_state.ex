defmodule Rail.Issues.Actions.AdvanceIssueState do
  @moduledoc """
  Queues a move of the issue's tracker status to match its task's stage, so a slow
  or failing tracker retries in the background instead of failing whatever asked.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.AdvanceTrackerState

  @doc """
  Enqueues `Rail.Issues.Workers.AdvanceTrackerState` to move `issue` forward.
  """
  def advance_issue_state(%Issue{} = issue) do
    %{issue_id: issue.id}
    |> AdvanceTrackerState.new()
    |> Oban.insert()
  end
end
