defmodule Rail.Pipeline.Actions.CreateFindingComment do
  @moduledoc """
  Saves a comment on one piece of a Review finding, unsent, for the person writing it, quoting the piece as it reads
  now. Any finding of the task takes one, however it is ruled, from Review on, at Finalize and after the merge too,
  until the task is cleaned up.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastFindingComments

  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Saves `attrs`, the `finding_id`, its `piece` with the `index` of a place or a note, and the comment's `body`, as the
  scope user's comment on `task`.

  Returns `{:ok, comment}` with its finding, `{:error, changeset}`, or `{:error, reason}` when the task is cleaned up,
  has not reached Review, or has no such finding or piece.
  """
  def create_finding_comment(%Scope{user: %{id: user_id}}, %Task{id: task_id}, attrs) do
    changeset = FindingComment.changeset(%FindingComment{task_id: task_id, user_id: user_id}, attrs)
    finding_id = Ecto.Changeset.get_field(changeset, :finding_id)
    piece = Ecto.Changeset.get_field(changeset, :piece)
    index = Ecto.Changeset.get_field(changeset, :index)

    # Read again, so a page drawn before the task moved on cannot write after it.
    with %Task{cleaned_up_at: nil, stage: stage} when stage in [:review, :finalize, :merged] <-
           Repo.get!(Task, task_id),
         %Finding{} = finding <-
           finding_id && Repo.one(from f in Finding, where: f.id == ^finding_id and f.task_id == ^task_id),
         %{label: label, quote: quote} <- FindingComment.calculate_piece(finding, piece, index),
         {:ok, comment} <- changeset |> Ecto.Changeset.change(label: label, quote: quote) |> Repo.insert() do
      broadcast_finding_comments(task_id, user_id)
      {:ok, %{comment | finding: finding}}
    else
      %Task{cleaned_up_at: %DateTime{}} -> {:error, :cleaned_up}
      %Task{stage: stage} -> {:error, {:invalid_stage, stage}}
      nil -> {:error, :not_found}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
