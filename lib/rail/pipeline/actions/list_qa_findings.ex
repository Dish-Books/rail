defmodule Rail.Pipeline.Actions.ListQaFindings do
  @moduledoc """
  The findings QA raised against a task, ordered by what each one is so that no
  ruling or fix ever moves one, and the reader keeps their place.

  What this change broke comes before what it merely stands next to, then it is
  worst first. `inserted_at` survives a re-sync, so a later pass does not
  reshuffle them either.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.QaFinding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Lists every finding on `task`: regressions before what this change did not
  cause, worst first, oldest first within a severity, with `id` breaking any tie.
  """
  def list_qa_findings(%Task{id: task_id}) do
    rank = QaFinding.severities() |> Enum.with_index() |> Map.new()

    from(f in QaFinding, where: f.task_id == ^task_id)
    |> Repo.all()
    # A `DateTime` compares field by field in term order, not by time.
    |> Enum.sort_by(
      &{pre_existing(&1), Map.fetch!(rank, &1.severity), DateTime.to_unix(&1.inserted_at, :microsecond), &1.id}
    )
  end

  defp pre_existing(%QaFinding{} = finding), do: if(QaFinding.regression?(finding), do: 0, else: 1)
end
