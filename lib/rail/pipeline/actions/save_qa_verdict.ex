defmodule Rail.Pipeline.Actions.SaveQaVerdict do
  @moduledoc """
  Checks the verdict a QA pass saved and writes it where `read_qa_report/1` reads
  it; saving it is how a pass says it is finished.
  """

  import Ecto.Changeset
  import Rail.Pipeline.Utils.WriteScratchFile

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaReport
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Saves `attrs` as `task`'s QA verdict. Returns `{:ok, report}` or `{:error, changeset}`.
  """
  def save_qa_verdict(%Task{} = task, attrs) when is_map(attrs) do
    %Task{issue: %Issue{identifier: identifier}} = task = Repo.preload(task, :issue)

    with {:ok, %QaReport{} = report} <- %QaReport{} |> QaReport.changeset(attrs) |> apply_action(:insert) do
      body = %{verdict: report.verdict, summary: report.summary, not_checked: report.not_checked}

      write_scratch_file(Path.join([task.scratch_path, "qa", "#{identifier}.json"]), Jason.encode!(body, pretty: true))
      Pipeline.broadcast_output_saved(task)

      {:ok, report}
    end
  end
end
