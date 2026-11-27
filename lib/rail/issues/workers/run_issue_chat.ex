defmodule Rail.Issues.Workers.RunIssueChat do
  @moduledoc """
  Runs the issue chat's agent once on an issue.
  """
  use Oban.Worker,
    queue: :issue_chat,
    max_attempts: 3,
    unique: [keys: [:issue_id], period: :infinity, states: [:available, :scheduled]]

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"issue_id" => id}}) do
    case Repo.get(Issue, id) do
      %Issue{} = issue -> Issues.run_issue_chat(issue)
      nil -> :ok
    end
  end
end
