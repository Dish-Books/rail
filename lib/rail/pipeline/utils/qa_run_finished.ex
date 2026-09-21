defmodule Rail.Pipeline.Utils.QaRunFinished do
  @moduledoc """
  Where a finished QA run leaves its task.

  Nowhere: the findings are recorded and the task stays at QA, because what
  happens next is the human's to say. QA reports and a person decides, so a pass
  that drove the whole application still moves nothing.

  What a QA run can get wrong is exiting cleanly having written no report, and
  that is recorded on the run so the stage stays open for the message that fixes
  it.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaReport
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc "Finishes `run` as the QA stage."
  def qa_run_finished(%Run{} = run, _opts) do
    task = Repo.preload(run.task, :issue)

    case Pipeline.read_qa_report(task) do
      %QaReport{findings: findings} ->
        {:ok, _synced} = Pipeline.sync_qa_findings(task, findings)
        run

      nil ->
        fail(run, "The QA agent did not write #{report_file(task)}.")
    end
  end

  defp report_file(%Task{issue: %Issue{identifier: identifier}}), do: "qa/#{identifier}.json"

  defp fail(%Run{} = run, error) do
    {:ok, failed} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{failed | task: run.task, role: run.role}
  end
end
