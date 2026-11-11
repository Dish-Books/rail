defmodule Rail.Issues.Actions.BlockIssue do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueRelation
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Records that `blocker` blocks `blocked`, two Rail-tracked issues of one project, and broadcasts
  `{:issue_relations_changed, [blocker_id, blocked_id]}` on `"issues"`. A pair already related either way stays as it is.
  """
  def block_issue(%Scope{} = scope, %Issue{id: blocker_id}, %Issue{id: blocked_id, project_id: project_id}) do
    held =
      from(i in Issue,
        where: i.id in ^[blocker_id, blocked_id] and i.project_id == ^project_id,
        select: {i.id, i.tracker}
      )
      |> Repo.all()
      |> Map.new()

    cond do
      not Scope.can_access_project?(scope, project_id) or not Map.has_key?(held, blocker_id) or
          not Map.has_key?(held, blocked_id) ->
        {:error, :not_found}

      Enum.any?(held, &match?({_id, tracker} when tracker != :local, &1)) ->
        {:error, :unsupported}

      true ->
        %IssueRelation{project_id: project_id}
        |> IssueRelation.changeset(%{blocker_issue_id: blocker_id, blocked_issue_id: blocked_id})
        |> Repo.insert(
          on_conflict: :nothing,
          conflict_target:
            {:unsafe_fragment,
             "(least(blocker_issue_id, blocked_issue_id), greatest(blocker_issue_id, blocked_issue_id))"}
        )
        |> then(fn
          {:ok, _relation_or_conflict} ->
            Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_relations_changed, [blocker_id, blocked_id]})

          {:error, changeset} ->
            {:error, changeset}
        end)
    end
  end
end
