defmodule Rail.Issues.Actions.ResetIssueState do
  @moduledoc """
  Moves an issue back, locally and then in its tracker: to not started for Discard, to In Progress for Back to Plan.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo

  @doc """
  Writes `issue` back to `state` and returns `{:ok, issue}` as written. Both callers run it in a transaction and
  tell open issue pages once it commits, so nothing is broadcast here.
  """
  def reset_issue_state(%Issue{} = issue, state) do
    issue |> Issue.reset_changeset(state) |> Repo.update()
  end
end
