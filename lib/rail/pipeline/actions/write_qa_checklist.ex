defmodule Rail.Pipeline.Actions.WriteQaChecklist do
  @moduledoc """
  Writes the checklist a QA pass is working to into its task's scratch directory.

  The whole list every time, because it is a statement of the pass rather than a
  journal of it: the rows are written before anything is driven and each one
  carries whatever it has come to since. `Rail.Pipeline.record_qa_check/4` marks a
  row off by handing the list back through here.

  Nothing is appended and nothing is merged. A second call replaces the file, so a
  pass that re-plans mid-way says so rather than leaving a row nobody will reach.
  """

  alias Rail.Pipeline.Schemas.QaCheck
  alias Rail.Pipeline.Schemas.QaChecklist
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Records `checks` as `task`'s checklist and returns it, or the changeset that
  refused it.
  """
  def write_qa_checklist(%Task{scratch_path: scratch_path}, checks) when is_list(checks) do
    changeset = QaChecklist.changeset(%QaChecklist{}, %{checks: checks})

    with {:ok, %QaChecklist{} = checklist} <- Ecto.Changeset.apply_action(changeset, :insert) do
      path = Path.join([scratch_path, "qa", "checklist.json"])

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode_to_iodata!(%{checks: Enum.map(checklist.checks, &row/1)}))

      {:ok, checklist}
    end
  end

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
