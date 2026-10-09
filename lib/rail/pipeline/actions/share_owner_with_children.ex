defmodule Rail.Pipeline.Actions.ShareOwnerWithChildren do
  @moduledoc """
  Gives a split parent's owner to each of its children, the only owner a child can have. A child
  that had none has its Linear status moved on by the write, as a claim's does.
  """

  import Ecto.Query

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Sets the owner of every child of `issue`'s task whose owner differs to `issue`'s. Returns
  `{:ok, children}` with the issues it changed, an empty list for an issue with no split.
  """
  def share_owner_with_children(%Issue{id: issue_id, owner_user_id: owner_user_id}) do
    query =
      from(i in Issue,
        join: c in Task,
        on: c.issue_id == i.id,
        join: p in Task,
        on: c.parent_task_id == p.id,
        where: p.issue_id == ^issue_id,
        where: fragment("? IS DISTINCT FROM ?", i.owner_user_id, ^owner_user_id)
      )

    children =
      for child <- Repo.all(query) do
        {:ok, child} = Issues.update_issue(child, %{owner_user_id: owner_user_id})
        child
      end

    {:ok, children}
  end
end
