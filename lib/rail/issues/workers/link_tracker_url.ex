defmodule Rail.Issues.Workers.LinkTrackerUrl do
  @moduledoc """
  Links a URL to an issue's ticket in its tracker, such as the Slack thread triage filed it from.

  The tracker keeps one link per URL, so a retry after a link that did go through adds no second one.
  """
  use Oban.Worker,
    queue: :issues,
    max_attempts: 5,
    unique: [keys: [:issue_id, :url], states: :incomplete, period: :infinity]

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Tracker
  alias Rail.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"issue_id" => issue_id, "url" => url, "title" => title}}) do
    case Repo.get(Issue, issue_id) do
      %Issue{} = issue -> issue |> Repo.preload(:project) |> then(&Tracker.tracker(&1).link_url(&1, url, title))
      nil -> :ok
    end
  end
end
