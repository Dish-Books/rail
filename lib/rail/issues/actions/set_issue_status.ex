defmodule Rail.Issues.Actions.SetIssueStatus do
  @moduledoc """
  A person's status change: the tracker hears first and the row is written from its answer. The row is locked for the
  write, as the Linear webhook locks it, so whichever of the two finishes the issue is the one that says so.
  """

  import Ecto.Query
  import Rail.Issues.Utils.WriteIssueStatus

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Tracker
  alias Rail.Repo
  alias Rail.Scope

  @written [:state, :state_name, :completed_at, :external_updated_at]

  @doc """
  Moves `issue` to `status`, one `Rail.Issues.get_statuses/2` returned, and broadcasts `{:issue_changed, issue_id}` on
  `"issues"`. Returns the row as it now reads, and sends nothing when the issue already has that status.
  """
  def set_issue_status(%Scope{} = scope, %Issue{id: id, project_id: project_id}, %{name: name} = status) do
    # Read again: a queued click can arrive with the page's copy one pick behind.
    current = Repo.one(from(i in Issue, where: i.id == ^id and i.project_id == ^project_id, preload: :project))

    cond do
      is_nil(current) or not Scope.can_access_project?(scope, project_id) ->
        {:error, :not_found}

      Issue.calculate_status_name(current) == name ->
        {:ok, current}

      true ->
        with {:ok, attrs} <- Tracker.tracker(current).set_status(scope, current, status),
             do: write_issue_status(current, &calculate_written(&1, attrs))
    end
  end

  # A webhook newer than this answer has already said where the ticket went.
  defp calculate_written(%Issue{external_updated_at: %DateTime{} = held}, %{external_updated_at: answered} = attrs) do
    if DateTime.before?(answered, held), do: %{}, else: Map.take(attrs, @written)
  end

  defp calculate_written(%Issue{}, attrs), do: Map.take(attrs, @written)
end
