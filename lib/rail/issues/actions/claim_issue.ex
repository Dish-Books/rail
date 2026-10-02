defmodule Rail.Issues.Actions.ClaimIssue do
  @moduledoc """
  Assigns an unassigned issue to the scope's user. Linear hears about it from the
  sync the write enqueues, which is why a user who never linked Linear cannot claim.

  An unowned ticket's Linear status is held back while its task runs, so the claim
  also queues the move that catches it up.
  """

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Makes the scope's user the owner of `issue`, unless somebody already is.
  """
  def claim_issue(%Scope{user: %{linear_user_id: linear_user_id} = user}, %Issue{} = issue)
      when is_binary(linear_user_id) do
    Repo.transaction(fn ->
      # Read again: somebody may have claimed it since the page loaded.
      case Repo.get_by!(Issue, id: issue.id, project_id: issue.project_id) do
        %Issue{owner_user_id: owner_user_id} when is_binary(owner_user_id) ->
          Repo.rollback(:already_assigned)

        %Issue{} = unassigned ->
          with {:ok, claimed} <- unassigned |> Issue.changeset(%{owner_user_id: user.id}) |> Repo.update(),
               {:ok, _job} <- Issues.advance_issue_state(claimed) do
            claimed
          else
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  def claim_issue(%Scope{}, %Issue{}), do: {:error, :linear_not_linked}
end
