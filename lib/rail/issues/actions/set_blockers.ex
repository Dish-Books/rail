defmodule Rail.Issues.Actions.SetBlockers do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueRelation
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Makes the tickets blocking a Rail-tracked `issue` exactly `blockers`, issues of its project: unblocks what is no longer
  listed, then blocks what is new. A listed ticket this one already blocks is refused before anything is written, as
  `{:error, {:already_blocks, identifiers}}`, since `Rail.Issues.block_issue/3` leaves a reversed pair as it is, and a
  list naming the issue itself as `{:error, :blocks_itself}`. Returns `{:ok, issue}`, `{:error, :unsupported}` on another tracker, or `{:error, :not_found}`.
  """
  def set_blockers(%Scope{} = scope, %Issue{project_id: project_id} = issue, blockers) when is_list(blockers) do
    cond do
      not Scope.can_access_project?(scope, project_id) -> {:error, :not_found}
      issue.tracker != :local -> {:error, :unsupported}
      true -> replace(scope, issue, Enum.uniq_by(blockers, & &1.id))
    end
  end

  defp replace(scope, %Issue{id: id, project_id: project_id} = issue, blockers) do
    relations =
      Repo.all(
        from(r in IssueRelation,
          where: r.project_id == ^project_id and (r.blocker_issue_id == ^id or r.blocked_issue_id == ^id),
          preload: :blocker_issue
        )
      )

    blocked_by = for %IssueRelation{blocked_issue_id: ^id, blocker_issue: blocker} <- relations, do: blocker
    blocks = for %IssueRelation{blocker_issue_id: ^id, blocked_issue_id: blocked_id} <- relations, do: blocked_id
    current_ids = Enum.map(blocked_by, & &1.id)
    wanted_ids = Enum.map(blockers, & &1.id)

    reversed = for %Issue{id: blocker_id} = blocker <- blockers, blocker_id in blocks, do: blocker.identifier

    cond do
      id in wanted_ids ->
        {:error, :blocks_itself}

      reversed != [] ->
        {:error, {:already_blocks, reversed}}

      true ->
        with :ok <- each(Enum.reject(blocked_by, &(&1.id in wanted_ids)), &Issues.unblock_issue(scope, &1, issue)),
             :ok <- each(Enum.reject(blockers, &(&1.id in current_ids)), &Issues.block_issue(scope, &1, issue)),
             do: {:ok, issue}
    end
  end

  defp each(issues, write) do
    Enum.reduce_while(issues, :ok, fn issue, :ok ->
      case write.(issue) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
