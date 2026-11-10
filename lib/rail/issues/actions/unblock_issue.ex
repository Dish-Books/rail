defmodule Rail.Issues.Actions.UnblockIssue do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueRelation
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Removes the relation in which `blocker` blocks `blocked`, and broadcasts `{:issue_relations_changed, [blocker_id,
  blocked_id]}` on `"issues"`. One already gone is removed too.
  """
  def unblock_issue(
        %Scope{} = scope,
        %Issue{id: blocker_id, project_id: project_id} = blocker,
        %Issue{id: blocked_id, project_id: project_id} = blocked
      ) do
    cond do
      not Scope.can_access_project?(scope, project_id) ->
        {:error, :not_found}

      blocker.tracker != :local or blocked.tracker != :local ->
        {:error, :unsupported}

      true ->
        Repo.delete_all(
          from(r in IssueRelation,
            where: r.project_id == ^project_id and r.blocker_issue_id == ^blocker_id and r.blocked_issue_id == ^blocked_id
          )
        )

        Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_relations_changed, [blocker_id, blocked_id]})
    end
  end

  def unblock_issue(%Scope{}, %Issue{}, %Issue{}), do: {:error, :not_found}
end
