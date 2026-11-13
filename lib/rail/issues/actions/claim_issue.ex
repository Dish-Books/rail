defmodule Rail.Issues.Actions.ClaimIssue do
  @moduledoc """
  Assigns an unassigned issue to the scope's user, who must have connected GitHub. The tracker hears about it from the
  sync the write enqueues, so it has to be one the tracker can name, such as a user who linked Linear.

  An unowned ticket's tracker status is held back while its task runs. The write
  queues the move that catches it up, as any write that gives an issue an owner does.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Tracker
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @doc """
  Makes the scope's user the owner of `issue`, unless somebody already is, or says why they cannot own it:
  `{:error, :github_not_linked}` for someone without GitHub, or the tracker's own refusal.
  """
  def claim_issue(%Scope{user: %User{id: user_id}}, %Issue{} = issue) do
    # Read again, since a page's scope can be from before they disconnected GitHub.
    with %User{github_id: github_id} = user when is_binary(github_id) <- Repo.get(User, user_id) || {:error, :not_found},
         :ok <- Tracker.tracker(issue).check_assignable(user) do
      claim(user, issue)
    else
      %User{} -> {:error, :github_not_linked}
      {:error, reason} -> {:error, reason}
    end
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
