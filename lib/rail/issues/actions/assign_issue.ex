defmodule Rail.Issues.Actions.AssignIssue do
  @moduledoc """
  A person's change of who owns an issue, with the issue page's rules: only someone the owner menu offers, and never on
  a sub-issue of a split task, which keeps its parent's owner.
  """

  import Ecto.Query

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users

  @doc """
  Makes `owner_user_id` the owner of `issue`, or nobody for nil, and gives a split parent's owner to its children. The
  tracker hears it through `Rail.Issues.Workers.SyncIssue`, which tells open pages once it has. Returns the row as it
  now reads, `{:error, :split_child}`, `{:error, :not_assignable}` for someone the menu would not offer, or
  `{:error, :not_found}`.
  """
  def assign_issue(%Scope{} = scope, %Issue{id: id, project_id: project_id}, owner_user_id)
      when is_binary(owner_user_id) or is_nil(owner_user_id) do
    # Read again: a page's copy can be a pick behind.
    current = Repo.one(from(i in Issue, where: i.id == ^id and i.project_id == ^project_id, preload: :task))

    cond do
      is_nil(current) or not Scope.can_access_project?(scope, project_id) ->
        {:error, :not_found}

      match?(%Task{parent_task_id: parent_id} when is_binary(parent_id), current.task) ->
        {:error, :split_child}

      is_binary(owner_user_id) and
          not Enum.any?(
            Users.list_assignable_users(project_id: project_id, tracker: current.tracker),
            &(&1.id == owner_user_id)
          ) ->
        {:error, :not_assignable}

      true ->
        with {:ok, issue} <- Issues.update_issue(current, %{owner_user_id: owner_user_id}) do
          {:ok, _children} = Pipeline.share_owner_with_children(issue)
          {:ok, issue}
        end
    end
  end
end
