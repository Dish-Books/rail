defmodule Rail.Issues.Actions.ClaimIssue do
  @moduledoc """
  Assigns an unassigned issue to the scope's user. The tracker hears about it from the
  sync the write enqueues, so it has to be one the tracker can name, such as a user who linked Linear.

  An unowned ticket's tracker status is held back while its task runs. The write
  queues the move that catches it up, as any write that gives an issue an owner does.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Tracker
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Makes the scope's user the owner of `issue`, unless somebody already is, or says why the
  issue's tracker cannot take them as its owner.
  """
  def claim_issue(%Scope{user: user}, %Issue{} = issue) do
    with :ok <- Tracker.tracker(issue).check_assignable(user), do: claim(user, issue)
  end

  # No transaction of its own: a start claims inside its own, which a rollback here would abort.
  defp claim(user, %Issue{} = issue) do
    # Read again: somebody may have claimed it since the page loaded.
    case Repo.get_by!(Issue, id: issue.id, project_id: issue.project_id) do
      %Issue{owner_user_id: owner_user_id} when is_binary(owner_user_id) ->
        {:error, :already_assigned}

      %Issue{} = unassigned ->
        claimed = unassigned |> Issue.changeset(%{owner_user_id: user.id}) |> Repo.update!()
        {:ok, claimed}
    end
  end
end
