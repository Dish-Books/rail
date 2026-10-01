defmodule Rail.Pipeline.Actions.ListReviewFindings do
  @moduledoc """
  The findings raised against a task, ordered by what each one is so that no
  ruling or fix ever moves one, and the reader keeps their place.

  `inserted_at` survives a re-sync, so a later pass does not reshuffle them
  either. Severity's rank comes from the schema's own list, since `Ecto.Enum`
  stores it as text.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Lists every finding on `task`, worst first, oldest first within a severity,
  with `id` breaking any tie.
  """
  def list_review_findings(%Task{id: task_id}) do
    rank = ReviewFinding.severities() |> Enum.with_index() |> Map.new()

    from(f in ReviewFinding, where: f.task_id == ^task_id)
    |> Repo.all()
    # A `DateTime` compares field by field in term order, not by time.
    |> Enum.sort_by(&{Map.fetch!(rank, &1.severity), DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
  end
end
