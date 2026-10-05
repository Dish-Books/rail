defmodule Rail.Pipeline.Actions.SaveReviewFinding do
  @moduledoc """
  Upserts one finding the reviewer saved, by its key, so a later save restates it
  rather than raising it twice; the human's decision is never overwritten.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  # Every column the reviewer writes, and nothing else: `decision` is the human's
  # and `inserted_at` is when the problem was first raised.
  @restated [
    :title,
    :detail,
    :suggestion,
    :file,
    :line,
    :severity,
    :recommendation,
    :status,
    :updated_at
  ]

  @doc """
  Saves the finding in `attrs` on `task`. Returns `{:ok, finding}` as the row
  now stands, or `{:error, changeset}`.
  """
  def save_review_finding(%Task{} = task, attrs) when is_map(attrs) do
    changeset = ReviewFinding.changeset(%ReviewFinding{task_id: task.id}, Map.drop(attrs, [:task_id, "task_id"]))

    with {:ok, finding} <-
           Repo.insert(changeset, on_conflict: {:replace, @restated}, conflict_target: [:task_id, :key], returning: true) do
      Pipeline.broadcast_output_saved(task)
      {:ok, finding}
    end
  end
end
