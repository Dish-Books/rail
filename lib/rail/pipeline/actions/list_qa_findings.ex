defmodule Rail.Pipeline.Actions.ListQaFindings do
  @moduledoc """
  The findings QA raised against a task, in the order there is to work through them.

  What the human has dismissed sinks to the bottom: it is still shown, because
  what was dealt with is what makes "what is left" mean anything, but it is no
  longer something to read past. Above that line, what this change broke comes
  before what it merely stands next to - a pre-existing blocker is worth knowing
  about and is rarely this branch's job - and within each of those it is worst
  first.

  Severity is the order a reader wants and `Ecto.Enum` stores it as text, so the
  rank comes from the schema's own list rather than a copy of it in SQL.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.QaFinding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Lists every finding on `task`: regressions worst first, then what this change
  did not cause, then what the human dismissed, oldest first within each.
  """
  def list_qa_findings(%Task{id: task_id}) do
    rank = QaFinding.severities() |> Enum.with_index() |> Map.new()

    from(f in QaFinding, where: f.task_id == ^task_id, order_by: [asc: f.inserted_at, asc: f.id])
    |> Repo.all()
    |> Enum.sort_by(&{dismissed(&1), pre_existing(&1), Map.fetch!(rank, &1.severity)})
  end

  defp dismissed(%QaFinding{decision: :skip}), do: 1
  defp dismissed(%QaFinding{}), do: 0

  defp pre_existing(%QaFinding{} = finding), do: if(QaFinding.regression?(finding), do: 0, else: 1)
end
