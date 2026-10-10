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
  and then in the order written. `unsent: true` returns only the scope user's
  unsent ones, which the Review tray holds.
  """
  def list_diff_comments(%Scope{user: %{id: user_id}}, %Task{id: task_id}, opts) do
    seen =
      if opts[:unsent],
        do: dynamic([comment], comment.status == :unsent and comment.user_id == ^user_id),
        else: dynamic([comment], comment.status != :unsent or comment.user_id == ^user_id)

    Repo.all(
      from comment in DiffComment,
        where: comment.task_id == ^task_id,
        where: ^seen,
        order_by: [asc: comment.path, asc: comment.inserted_at, asc: comment.id],
        preload: [:user]
    )
  end

  def list_diff_comments(_no_user, %Task{id: task_id}, _opts) do
    Repo.all(
      from comment in DiffComment,
        where: comment.task_id == ^task_id and comment.status != :unsent,
        order_by: [asc: comment.path, asc: comment.inserted_at, asc: comment.id],
        preload: [:user]
    )
  end
end
