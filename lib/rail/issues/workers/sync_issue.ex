defmodule Rail.Issues.Workers.SyncIssue do
  @moduledoc """
  Pushes a local issue change up to its tracker.

  The job carries the names of the fields that actually changed and sends only
  those. Nothing is read back and nothing else is written, so an edit somebody
  made in the tracker to a field this change did not touch is still there afterwards.
  Rail is not the owner of the ticket; it is one of two writers.
  """
  use Oban.Worker, queue: :issues, max_attempts: 5

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Tracker
  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @pushable [:title, :description, :priority, :estimate, :state, :owner_user_id]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"issue_id" => issue_id, "fields" => fields} = args}) do
    case Repo.get(Issue, issue_id) do
      %Issue{} = issue -> push(Repo.preload(issue, [:project, :owner_user]), fields, args["previous_owner_user_id"])
      nil -> :ok
    end
  end

  defp push(%Issue{} = issue, fields, previous_owner_user_id) do
    case fields |> Enum.map(&to_existing_field/1) |> Enum.filter(&(&1 in @pushable)) do
      [] ->
        :ok

      pushable ->
        previous_owner = previous_owner_user_id && Repo.get(User, previous_owner_user_id)
        Tracker.tracker(issue).update_issue(issue, pushable, previous_owner)
    end
  end

  # Job args come back from JSON, so field names are always strings.
  defp to_existing_field(field) when is_binary(field) do
    String.to_existing_atom(field)
  rescue
    ArgumentError -> :unknown
  end
end
