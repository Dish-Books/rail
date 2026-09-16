defmodule Rail.Pipeline.Actions.ListReviewFindings do
  @moduledoc """
  The findings raised against a task, worst first.

  Severity is the order a reader wants and `Ecto.Enum` stores it as text, so the
  rank comes from the schema's own list rather than a copy of it in SQL.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Lists every finding on `task`, most severe first and oldest first within a
  severity.
  """
  def list_review_findings(%Task{id: task_id}) do
    rank = ReviewFinding.severities() |> Enum.with_index() |> Map.new()

    from(f in ReviewFinding, where: f.task_id == ^task_id, order_by: [asc: f.inserted_at, asc: f.id])
    |> Repo.all()
    |> Enum.sort_by(&Map.fetch!(rank, &1.severity))
  end
end
