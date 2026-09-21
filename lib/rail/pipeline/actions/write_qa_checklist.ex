defmodule Rail.Pipeline.Actions.WriteQaChecklist do
  @moduledoc """
  Writes the checklist a QA pass is working to into its task's scratch directory.

  The whole list every time, because it is a statement of the pass rather than a
  journal of it: the rows are written before anything is driven and each one
  carries whatever it has come to since. `Rail.Pipeline.record_qa_check/4` marks a
  row off by handing the list back through here.

  A second call replaces the file, so a pass that re-plans mid-way says so rather
  than leaving a row nobody will reach. One thing survives it: a row whose key
  was already on the list and had been run keeps its outcome, marked as carried.

  That is what makes a second QA pass affordable. The pass lists every check
  again, re-runs the ones the new commits could have touched, and the rest stand
  as they were answered rather than being driven a second time for no reason.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaCheck
  alias Rail.Pipeline.Schemas.QaChecklist
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Records `checks` as `task`'s checklist and returns it, or the changeset that
  refused it.
  """
  def write_qa_checklist(%Task{} = task, checks) when is_list(checks) do
    changeset = QaChecklist.changeset(%QaChecklist{}, %{checks: checks})

    with {:ok, %QaChecklist{} = checklist} <- Ecto.Changeset.apply_action(changeset, :insert) do
      checklist = %{checklist | checks: Enum.map(checklist.checks, &carry(&1, answered(task)))}
      path = Path.join([task.scratch_path, "qa", "checklist.json"])

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode_to_iodata!(%{checks: Enum.map(checklist.checks, &row/1)}))

      {:ok, checklist}
    end
  end

  # What the list on disk already came to, by key. A first pass has none of this
  # and a re-plan mid-pass has whatever the pass has run so far.
  defp answered(%Task{} = task) do
    case Pipeline.read_qa_checklist(task) do
      {:ok, %QaChecklist{checks: checks}} -> Map.new(checks, &{&1.key, &1})
      {:error, :qa_checklist_not_found} -> %{}
    end
  end

  # A row the pass has not answered, which an earlier list did, is answered
  # already - and says that the answer is not this pass's.
  defp carry(%QaCheck{outcome: :pending} = check, answered) do
    case answered[check.key] do
      %QaCheck{outcome: :pending} -> check
      %QaCheck{} = ran -> %{check | outcome: ran.outcome, note: ran.note, carried: true}
      nil -> check
    end
  end

  defp carry(%QaCheck{} = check, _answered), do: check

  defp row(%QaCheck{} = check) do
    %{
      key: check.key,
      title: check.title,
      group: check.group,
      criterion: check.criterion,
      outcome: check.outcome,
      note: check.note,
      carried: check.carried
    }
  end
end
