defmodule Rail.Issues.Actions.AdvanceIssueState do
  @moduledoc """
  Queues a move of the issue's Linear status to `state`, so a slow or failing
  Linear retries in the background instead of failing whatever asked for it.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.AdvanceLinearState

  @doc """
  Enqueues `Rail.Issues.Workers.AdvanceLinearState` to move `issue` forward to `state`.
  """
  def advance_issue_state(%Issue{} = issue, state) when state in [:todo, :in_progress, :in_review] do
    %{issue_id: issue.id, state: state}
    |> AdvanceLinearState.new()
    |> Oban.insert()
  end
end
