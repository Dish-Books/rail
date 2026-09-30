defmodule Rail.Pipeline.Actions.ListDiffComments do
  @moduledoc """
  The comments this reader has written on a task's diff and not yet sent.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Returns the scope user's comments on `task`, by file and then in the order written.
  """
  def list_diff_comments(%Scope{user: %{id: user_id}}, %Task{id: task_id}) do
    Repo.all(
      from comment in DiffComment,
        where: comment.task_id == ^task_id and comment.user_id == ^user_id,
        order_by: [asc: comment.path, asc: comment.inserted_at, asc: comment.id]
    )
  end

  def list_diff_comments(_no_user, %Task{}), do: []
end
