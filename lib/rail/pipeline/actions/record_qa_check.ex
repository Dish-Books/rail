defmodule Rail.Pipeline.Actions.RecordQaCheck do
  @moduledoc """
  Marks one row of a QA pass's checklist as run.

  A row is marked as the pass reaches it rather than at the end, which is what
  makes the panel worth watching: the human sees the third of forty checks go
  green while it is happening, and a pass that stalls stalls somewhere visible.

  Only a row the checklist already names can be marked. That is not a guard
  against mischief so much as against drift - a pass reporting against a check it
  never listed has changed its mind about what it is doing, and the honest move is
  to write the checklist again.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaCheck
  alias Rail.Pipeline.Schemas.QaChecklist
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Records `outcome` against the check `key` on `task`, with an optional `note`.

  Returns the row as it now stands, `{:error, :qa_checklist_not_found}` when the
  pass never wrote one, or `{:error, :qa_check_not_found}` for a key it does not
  name.
  """
  def record_qa_check(%Task{} = task, key, outcome, note \\ nil) do
    with {:ok, %QaChecklist{checks: checks}} <- Pipeline.read_qa_checklist(task),
         {:ok, %QaCheck{}} <- named(checks, key),
         {:ok, %QaChecklist{} = written} <-
           Pipeline.write_qa_checklist(task, Enum.map(checks, &mark(&1, key, outcome, note))) do
      {:ok, Enum.find(written.checks, &(&1.key == key))}
    else
      {:error, %Ecto.Changeset{}} -> {:error, :unusable_outcome}
      {:error, reason} -> {:error, reason}
    end
  end

  defp named(checks, key) do
    case Enum.find(checks, &(&1.key == key)) do
      %QaCheck{} = check -> {:ok, check}
      nil -> {:error, :qa_check_not_found}
    end
  end

  defp mark(%QaCheck{key: key} = check, key, outcome, note) do
    check |> row() |> Map.merge(%{outcome: outcome, note: note || check.note})
  end

  defp mark(%QaCheck{} = check, _other, _outcome, _note), do: row(check)

  defp row(%QaCheck{} = check) do
    %{
      key: check.key,
      title: check.title,
      group: check.group,
      criterion: check.criterion,
      outcome: check.outcome,
      note: check.note
    }
  end
end
