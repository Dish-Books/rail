defmodule Rail.Issues.Workers.SyncIssue do
  @moduledoc """
  Tells the pages showing an issue that it changed, as `{:issue_changed, issue_id}` on `"issues"`. `Issue.changeset/2`
  queues it inside the write's own transaction, so it runs only once the change is there to read.
  """
  use Oban.Worker, queue: :issues, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"issue_id" => issue_id}}),
    do: Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, issue_id})
end
