defmodule Rail.Pipeline.Utils.IssueIdentifier do
  @moduledoc """
  The Linear identifier of the issue behind a task.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Returns the issue identifier for `task`, or `nil` when it has no issue.
  """
  def issue_identifier(%Task{issue: %Issue{identifier: id}}) when is_binary(id) and id != "", do: id

  def issue_identifier(%Task{issue_id: issue_id}) when is_binary(issue_id) do
    case Repo.get(Issue, issue_id) do
      %Issue{identifier: id} -> id
      nil -> nil
    end
  end

  def issue_identifier(_other), do: nil
end
