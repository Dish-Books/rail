defmodule Rail.Pipeline.Actions.ReadQaChecklist do
  @moduledoc """
  Reads the checklist a QA pass is working to out of its task's scratch directory.

  Rail wrote the file, so this is not defending against an agent the way the
  report reader is - but the file is on disk between two processes and a pass that
  died mid-write would leave half a line, so anything that does not come back as a
  checklist reads as none at all. The panel then shows what it showed before the
  pass started, rather than an error about a file the human never asked about.
  """

  alias Rail.Pipeline.Schemas.QaChecklist
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Returns `{:ok, checklist}` for `task`, or `{:error, :qa_checklist_not_found}`
  when there is nothing readable to show.

  Named rather than `nil`, because the caller that marks a row off has two ways
  to find nothing - no checklist at all, and no such row on it - and they are
  different things to tell the agent.
  """
  def read_qa_checklist(%Task{scratch_path: scratch_path}) do
    path = Path.join([scratch_path, "qa", "checklist.json"])

    with {:ok, content} <- File.read(path),
         {:ok, %{"checks" => checks}} when is_list(checks) <- Jason.decode(content),
         {:ok, %QaChecklist{} = checklist} <-
           %QaChecklist{} |> QaChecklist.changeset(%{checks: checks}) |> Ecto.Changeset.apply_action(:insert) do
      {:ok, checklist}
    else
      _unreadable -> {:error, :qa_checklist_not_found}
    end
  end
end
