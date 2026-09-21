defmodule Rail.Pipeline.Actions.ListReviewFindings do
  @moduledoc """
  The findings raised against a task, in the order there is to work through them.

  Four bands, and within each it is worst first. What is waiting on a human comes
  first, because nothing moves until every one of them has been ruled on: the
  buttons that send the change back or on stay hidden while one is unread. Then
  what has been ruled on and is still to fix. Then what the engineer has fixed.
  Then what the human dismissed, which is last whatever else is true of it.

  Nothing is hidden: what was dealt with is what makes "what is left" mean
  anything. It is only no longer something to read past.

  Severity is the order a reader wants and `Ecto.Enum` stores it as text, so the
  rank comes from the schema's own list rather than a copy of it in SQL.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Lists every finding on `task`: the ones still to rule on worst first, then the
  ones ruled on and outstanding, then the fixed, then the dismissed, oldest
  first within each.
  """
  def list_review_findings(%Task{id: task_id}) do
    rank = ReviewFinding.severities() |> Enum.with_index() |> Map.new()

    from(f in ReviewFinding, where: f.task_id == ^task_id, order_by: [asc: f.inserted_at, asc: f.id])
    |> Repo.all()
    |> Enum.sort_by(&{band(&1), Map.fetch!(rank, &1.severity)})
  end

  # A dismissal is the human's last word on a finding, so it sorts last however
  # it stands otherwise.
  defp band(%ReviewFinding{decision: :skip}), do: 3
  defp band(%ReviewFinding{status: :fixed}), do: 2
  defp band(%ReviewFinding{} = finding), do: if(ReviewFinding.undecided?(finding), do: 0, else: 1)
end
