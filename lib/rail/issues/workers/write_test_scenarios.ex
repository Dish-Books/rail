defmodule Rail.Issues.Workers.WriteTestScenarios do
  @moduledoc """
  Writes a merged ticket's test scenarios, outside the merge that asked for them.
  """
  use Oban.Worker,
    queue: :testing_agent,
    max_attempts: 3,
    unique: [keys: [:issue_id], states: :incomplete, period: :infinity]

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"issue_id" => id, "merge_sha" => merge_sha}}) do
    case Repo.get(Issue, id) do
      %Issue{} = issue -> Issues.write_test_scenarios(issue, merge_sha)
      nil -> :ok
    end
  end
end
