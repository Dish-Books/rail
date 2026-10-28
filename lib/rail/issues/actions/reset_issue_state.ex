defmodule Rail.Issues.Actions.ResetIssueState do
  @moduledoc """
  Moves an issue back to not started, locally and then in its tracker, for a task discarded to start over.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo

  @doc """
  Writes `issue` back to `todo` and tells open issue pages. Returns `{:ok, issue}` as written.
  """
  def reset_issue_state(%Issue{} = issue) do
    with {:ok, reset} <- issue |> Issue.reset_changeset() |> Repo.update() do
      Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, reset.id})
      {:ok, reset}
    end
  end
end
