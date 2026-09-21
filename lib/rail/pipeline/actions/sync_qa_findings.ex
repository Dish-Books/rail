defmodule Rail.Pipeline.Actions.SyncQaFindings do
  @moduledoc """
  Folds the findings a QA pass wrote into the rows the task already carries.

  A finding is matched by the key QA gave it, so a second pass updates what it
  said about the same defect rather than raising it again. What it may not touch
  is `decision`: that is the human's call, and a pass that overwrote it would
  re-open everything they dismissed every time it ran.

  A key QA dropped is left alone rather than deleted. It was raised once and
  ruled on once, and a pass that stopped listing it has said nothing about it.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.QaFinding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  # What a later pass is allowed to restate. `decision` is the human's and
  # `inserted_at` is when the defect was first raised, so neither is replaced,
  # and `id` stays whatever the row was given when it was inserted. A column QA
  # writes and this list forgets is a column that never reaches an existing row,
  # so every field in the changeset belongs here or is deliberately left out.
  @restated [
    :title,
    :check,
    :criterion,
    :screen,
    :steps,
    :expected,
    :observed,
    :detail,
    :suggestion,
    :severity,
    :recommendation,
    :status,
    :caused_by_change,
    :evidence,
    :updated_at
  ]

  @doc """
  Records `findings` against `task`, and returns them all as they now stand,
  oldest first.
  """
  def sync_qa_findings(%Task{} = task, findings) when is_list(findings) do
    {:ok, synced} =
      Repo.transaction(fn ->
        Enum.each(findings, &upsert(task, &1))
        rows(task)
      end)

    {:ok, synced}
  end

  defp rows(%Task{id: task_id}) do
    Repo.all(from f in QaFinding, where: f.task_id == ^task_id, order_by: [asc: f.inserted_at, asc: f.id])
  end

  defp upsert(%Task{} = task, finding) do
    %QaFinding{}
    |> QaFinding.changeset(Map.put(finding, :task_id, task.id))
    |> Repo.insert!(on_conflict: {:replace, @restated}, conflict_target: [:task_id, :key])
  end
end
