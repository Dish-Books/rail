defmodule Rail.Issues.Actions.SetIssueStatus do
  @moduledoc """
  A person's status change: the tracker hears first and the row is written from its answer. The row is locked for the
  write, as the Linear webhook locks it, so whichever of the two finishes the issue is the one that says so.
  """

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Tracker
  alias Rail.Learnings
  alias Rail.Pipeline
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
      is_nil(current) or not Scope.can_access_project?(scope, project_id) -> {:error, :not_found}
      Issue.calculate_status_name(current) == name -> {:ok, current}
      true -> with {:ok, attrs} <- Tracker.tracker(current).set_status(scope, current, status), do: write(current, attrs)
    end
  end

  defp write(%Issue{id: id, project_id: project_id}, attrs) do
    written =
      Repo.transaction(fn ->
        case Repo.one(from(i in Issue, where: i.id == ^id and i.project_id == ^project_id, lock: "FOR UPDATE")) do
          %Issue{} = locked -> {locked, write_unless_stale(locked, attrs)}
          nil -> Repo.rollback(:not_found)
        end
      end)

    with {:ok, {was, issue}} <- written do
      if not Issue.finished_state?(was.state) and Issue.finished_state?(issue.state) do
        {:ok, _job} = Learnings.handle_issue_finished(issue)
        Pipeline.handle_issue_finished(issue)
      end

      Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, id})
      {:ok, issue}
    end
  end

  # A webhook newer than this answer has already said where the ticket went.
  defp write_unless_stale(
         %Issue{external_updated_at: %DateTime{} = held} = issue,
         %{external_updated_at: answered} = attrs
       ) do
    if DateTime.before?(answered, held), do: issue, else: write_answer(issue, attrs)
  end

  defp write_unless_stale(%Issue{} = issue, attrs), do: write_answer(issue, attrs)

  defp write_answer(%Issue{} = issue, attrs) do
    issue |> Issue.tracker_changeset(Map.take(attrs, @written)) |> Repo.update!()
  end
end
