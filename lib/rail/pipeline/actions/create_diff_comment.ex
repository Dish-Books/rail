defmodule Rail.Pipeline.Actions.CreateDiffComment do
  @moduledoc """
  Saves a comment on one line of a task's diff, unsent, for the person writing it.
  """

  import Rail.Pipeline.Utils.BroadcastDiffComments

  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Saves `attrs` as the scope user's comment on `task`. Returns `{:ok, comment}`, `{:error, changeset}`, or
  `{:error, :cleaned_up}` once the task's worktree and branch are gone.
  """
  def create_diff_comment(%Scope{user: %{id: user_id}}, %Task{id: task_id}, attrs) do
    # Read again, so a page drawn before the cleanup cannot write after it.
    with %Task{cleaned_up_at: nil} <- Repo.get!(Task, task_id),
         {:ok, comment} <-
           %DiffComment{task_id: task_id, user_id: user_id} |> DiffComment.changeset(attrs) |> Repo.insert() do
      broadcast_diff_comments(task_id, user_id)
      {:ok, comment}
    else
      %Task{} -> {:error, :cleaned_up}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
