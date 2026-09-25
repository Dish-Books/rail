defmodule Rail.Issues.Actions.AdvanceIssueState do
  @moduledoc """
  Queues a move of the issue's Linear status to match its task's stage, so a slow
  or failing Linear retries in the background instead of failing whatever asked.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.AdvanceLinearState

  @doc """
  Enqueues `Rail.Issues.Workers.AdvanceLinearState` to move `issue` forward.
  """
  def advance_issue_state(%Issue{} = issue) do
    %{issue_id: issue.id}
    |> AdvanceLinearState.new()
    |> Oban.insert()
  end
end
