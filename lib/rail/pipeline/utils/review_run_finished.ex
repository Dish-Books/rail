defmodule Rail.Pipeline.Utils.ReviewRunFinished do
  @moduledoc """
  Where a finished review run leaves its task.

  Nowhere: the findings are recorded and the task stays at review, because what
  happens next is the human's to say. The reviewer recommends and a person
  decides, so a pass that read the change well enough to conclude something still
  moves nothing.

  What a review run can get wrong is exiting cleanly having written no report,
  and that is recorded on the run so the stage stays open for the message that
  fixes it.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc "Finishes `run` as the review stage."
  def review_run_finished(%Run{} = run, _opts) do
    task = Repo.preload(run.task, :issue)

    case Pipeline.read_review(task) do
      findings when is_list(findings) ->
        {:ok, _synced} = Pipeline.sync_review_findings(task, findings)
        run

      nil ->
        fail(run, "The reviewer did not write #{report_file(task)}.")
    end
  end

  defp report_file(%Task{issue: %Issue{identifier: identifier}}), do: "reviews/#{identifier}.json"

  defp fail(%Run{} = run, error) do
    {:ok, failed} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{failed | task: run.task, role: run.role}
  end
end
