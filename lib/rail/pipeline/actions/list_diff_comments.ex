defmodule Rail.Pipeline.Actions.ListDiffComments do
  @moduledoc """
  The comments a reader sees on a task's diff: everyone's sent and resolved ones,
  and their own unsent ones, which nobody else sees.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Returns the comments on `task` the scope user sees, with their authors, by file
  and then in the order written.
  """
  def list_diff_comments(%Scope{user: %{id: user_id}}, %Task{id: task_id}) do
    Repo.all(
      from comment in DiffComment,
        where: comment.task_id == ^task_id and (comment.status != :unsent or comment.user_id == ^user_id),
        order_by: [asc: comment.path, asc: comment.inserted_at, asc: comment.id],
        preload: [:user]
    )
  end

  def list_diff_comments(_no_user, %Task{id: task_id}) do
    Repo.all(
      from comment in DiffComment,
        where: comment.task_id == ^task_id and comment.status != :unsent,
        order_by: [asc: comment.path, asc: comment.inserted_at, asc: comment.id],
        preload: [:user]
    )
  end
end
