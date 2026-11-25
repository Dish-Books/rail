defmodule Rail.Issues.Actions.EditIssue do
  @moduledoc """
  A person's edit of an issue's title, description, priority, estimate or parent, on its page.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Writes `attrs` to `issue` and broadcasts `{:issue_changed, issue_id}` on `"issues"`. A `"parent_id"` names an issue of
  the same project, or clears the parent when empty. Returns the row as it now reads.
  """
  def edit_issue(%Scope{} = scope, %Issue{id: id, project_id: project_id}, %{} = attrs) do
    if Scope.can_access_project?(scope, project_id) do
      fn ->
        # Read again under the row lock the issue chat's pass writes under, so the two take turns.
        query = from(i in Issue, where: i.id == ^id and i.project_id == ^project_id, lock: "FOR UPDATE")

        with %Issue{} = current <- Repo.one(query) || {:error, :not_found},
             changeset = Issue.edit_changeset(current, Map.delete(attrs, "parent_id")),
             {:ok, changeset} <- put_parent(changeset, current, attrs),
             {:ok, issue} <- Repo.update(changeset) do
          issue
        else
          {:error, changeset_or_not_found} -> Repo.rollback(changeset_or_not_found)
        end
      end
      |> Repo.transaction()
      |> tap(fn
        {:ok, issue} -> Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, issue.id})
        {:error, _changeset_or_not_found} -> :ok
      end)
    else
      {:error, :not_found}
    end
  end

  defp put_parent(changeset, %Issue{}, %{"parent_id" => parent_id}) when parent_id in [nil, ""],
    do: {:ok, put_change(changeset, :parent_id, nil)}

  defp put_parent(changeset, %Issue{} = current, %{"parent_id" => parent_id}) when is_binary(parent_id) do
    # Two tabs making two issues each other's parent take turns here, so the second sees the first's parent.
    Repo.one!(from(p in Project, where: p.id == ^current.project_id, lock: "FOR UPDATE", select: p.id))
    parent = Repo.one(from(i in Issue, where: i.id == ^parent_id and i.project_id == ^current.project_id))

    cond do
      is_nil(parent) -> {:error, add_error(changeset, :parent_id, "is not an issue in this project")}
      parent.id == current.id -> {:error, add_error(changeset, :parent_id, "can't be the issue itself")}
      below_issue?(current, parent) -> {:error, add_error(changeset, :parent_id, "is a sub-issue of this issue")}
      true -> {:ok, put_change(changeset, :parent_id, parent.id)}
    end
  end

  defp put_parent(changeset, %Issue{}, %{}), do: {:ok, changeset}

  # The chain from the picked parent up to its root; `union` stops on a loop already in the data.
  defp below_issue?(%Issue{id: issue_id}, %Issue{id: parent_id}) do
    initial = from(i in Issue, where: i.id == ^parent_id, select: %{id: i.id, parent: i.parent_id})
    step = from(i in Issue, join: c in "chain", on: i.id == c.parent, select: %{id: i.id, parent: i.parent_id})

    from(c in "chain", where: c.id == ^issue_id, select: 1)
    |> recursive_ctes(true)
    |> with_cte("chain", as: ^union(initial, ^step))
    |> Repo.exists?()
  end
end
