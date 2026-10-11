defmodule Rail.Pipeline.Actions.CreateScreenComment do
  @moduledoc """
  Saves a comment on one screen state Review shot, unsent, for the person writing it, against the state's shot as it
  is now. It can be written from Review on, at Finalize and after the merge too, until the task is cleaned up.
  """

  import Rail.Pipeline.Utils.BroadcastScreenComments

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ScreenComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Saves `attrs`, the state's `key` and the comment's `body`, as the scope user's comment on `task`.

  Returns `{:ok, comment}`, `{:error, changeset}`, or `{:error, reason}` when the task is cleaned up, has not reached
  Review, or has no shot of that state.
  """
  def create_screen_comment(%Scope{user: %{id: user_id}}, %Task{id: task_id}, attrs) do
    changeset = ScreenComment.changeset(%ScreenComment{task_id: task_id, user_id: user_id}, attrs)

    # Read again, so a page drawn before the task moved on cannot write after it.
    with %Task{cleaned_up_at: nil, stage: stage} = task when stage in [:review, :finalize, :merged] <-
           Repo.get!(Task, task_id),
         key = Ecto.Changeset.get_field(changeset, :key),
         %{label: label, commit: commit} <- Enum.find(Pipeline.list_screens(task), &(&1.key == key)),
         {:ok, comment} <- changeset |> Ecto.Changeset.change(label: label, commit: commit) |> Repo.insert() do
      broadcast_screen_comments(task_id, user_id)
      {:ok, comment}
    else
      %Task{cleaned_up_at: %DateTime{}} -> {:error, :cleaned_up}
      %Task{stage: stage} -> {:error, {:invalid_stage, stage}}
      nil -> {:error, :not_found}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
