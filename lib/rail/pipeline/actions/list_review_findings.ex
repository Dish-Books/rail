defmodule Rail.Pipeline.Actions.ListReviewFindings do
  @moduledoc """
  The findings raised against a task, in the order there is to work through them.

  What the human has dismissed sinks to the bottom: it is still shown, because
  what was dealt with is what makes "what is left" mean anything, but it is no
  longer something to read past. Above that line it is worst first.

  Severity is the order a reader wants and `Ecto.Enum` stores it as text, so the
  rank comes from the schema's own list rather than a copy of it in SQL.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Lists every finding on `task`: the ones still standing worst first, then the
  ones the human dismissed, oldest first within each.
  """
  def list_review_findings(%Task{id: task_id}) do
    rank = ReviewFinding.severities() |> Enum.with_index() |> Map.new()

    from(f in ReviewFinding, where: f.task_id == ^task_id, order_by: [asc: f.inserted_at, asc: f.id])
    |> Repo.all()
    |> Enum.sort_by(&{dismissed(&1), Map.fetch!(rank, &1.severity)})
  end

  defp dismissed(%ReviewFinding{decision: :skip}), do: 1
  defp dismissed(%ReviewFinding{}), do: 0
end
