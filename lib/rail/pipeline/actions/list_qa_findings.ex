defmodule Rail.Pipeline.Actions.ListQaFindings do
  @moduledoc """
  The findings QA raised against a task, in the order there is to work through them.

  Four bands. What is waiting on a human comes first, because nothing moves until
  every one of them has been ruled on: the buttons that send the change back or
  on stay hidden while one is unread. Then what has been ruled on and is still to
  fix. Then what the engineer has fixed. Then what the human dismissed, which is
  last whatever else is true of it.

  Nothing is hidden: what was dealt with is what makes "what is left" mean
  anything. It is only no longer something to read past.

  Within each band, what this change broke comes before what it merely stands
  next to - a pre-existing blocker is worth knowing about and is rarely this
  branch's job - and within each of those it is worst first.

  Severity is the order a reader wants and `Ecto.Enum` stores it as text, so the
  rank comes from the schema's own list rather than a copy of it in SQL.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.QaFinding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Lists every finding on `task`: the ones still to rule on first, then the ones
  ruled on and outstanding, then the fixed, then the dismissed - and inside
  each, regressions before what this change did not cause, worst first, oldest
  first within each.
  """
  def list_qa_findings(%Task{id: task_id}) do
    rank = QaFinding.severities() |> Enum.with_index() |> Map.new()

    from(f in QaFinding, where: f.task_id == ^task_id, order_by: [asc: f.inserted_at, asc: f.id])
    |> Repo.all()
    |> Enum.sort_by(&{band(&1), pre_existing(&1), Map.fetch!(rank, &1.severity)})
  end

  # A dismissal is the human's last word on a finding, so it sorts last however
  # it stands otherwise.
  defp band(%QaFinding{decision: :skip}), do: 3
  defp band(%QaFinding{status: :fixed}), do: 2
  defp band(%QaFinding{} = finding), do: if(QaFinding.undecided?(finding), do: 0, else: 1)

  defp pre_existing(%QaFinding{} = finding), do: if(QaFinding.regression?(finding), do: 0, else: 1)
end
