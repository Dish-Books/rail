defmodule Rail.Issues.Actions.EditIssue do
  @moduledoc """
  A person's edit of a Rail-tracked issue's title, description, priority, estimate or parent, on its page.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Writes `attrs` to `issue` and broadcasts `{:issue_changed, issue_id}` on `"issues"`. A `"parent_id"` names an issue of
  the same project, or clears the parent when empty. Returns the row as it now reads, or `{:error, :unsupported}` for
  an issue another tracker holds.
  """
  def edit_issue(%Scope{} = scope, %Issue{id: id, project_id: project_id}, %{} = attrs) do
    # Read again: a page's copy can be a pick behind.
    current = Repo.one(from(i in Issue, where: i.id == ^id and i.project_id == ^project_id))

    cond do
      is_nil(current) or not Scope.can_access_project?(scope, project_id) ->
        {:error, :not_found}

      current.tracker != :local ->
        {:error, :unsupported}

      true ->
        fn ->
          changeset = Issue.edit_changeset(current, Map.delete(attrs, "parent_id"))

          with {:ok, changeset} <- put_parent(changeset, current, attrs),
               {:ok, issue} <- Repo.update(changeset) do
            issue
          else
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end
        |> Repo.transaction()
        |> tap(fn
          {:ok, issue} -> Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, issue.id})
          {:error, _changeset} -> :ok
        end)
    end
  end

  defp put_parent(changeset, %Issue{}, %{"parent_id" => parent_id}) when parent_id in [nil, ""],
    do: {:ok, put_change(changeset, :parent_external_id, nil)}

  defp put_parent(changeset, %Issue{} = current, %{"parent_id" => parent_id}) when is_binary(parent_id) do
    # Two tabs making two issues each other's parent take turns here, so the second sees the first's parent.
    Repo.one!(from(p in Project, where: p.id == ^current.project_id, lock: "FOR UPDATE", select: p.id))
    parent = Repo.one(from(i in Issue, where: i.id == ^parent_id and i.project_id == ^current.project_id))

    cond do
      is_nil(parent) -> {:error, add_error(changeset, :parent_id, "is not an issue in this project")}
      parent.id == current.id -> {:error, add_error(changeset, :parent_id, "can't be the issue itself")}
      below_issue?(current, parent) -> {:error, add_error(changeset, :parent_id, "is a sub-issue of this issue")}
      true -> {:ok, put_change(changeset, :parent_external_id, parent.external_id)}
    end
  end

  defp put_parent(changeset, %Issue{}, %{}), do: {:ok, changeset}

  # The chain from the picked parent up to its root; `union` stops on a loop already in the data.
  defp below_issue?(%Issue{external_id: external_id}, %Issue{id: parent_id}) do
    initial =
      from(i in Issue, where: i.id == ^parent_id, select: %{external_id: i.external_id, parent: i.parent_external_id})

    step =
      from(i in Issue,
        join: c in "chain",
        on: i.external_id == c.parent,
        select: %{external_id: i.external_id, parent: i.parent_external_id}
      )

    from(c in "chain", where: c.external_id == ^external_id, select: 1)
    |> recursive_ctes(true)
    |> with_cte("chain", as: ^union(initial, ^step))
    |> Repo.exists?()
  end
end
