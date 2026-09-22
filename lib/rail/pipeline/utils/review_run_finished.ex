defmodule Rail.Pipeline.Utils.ReviewRunFinished do
  @moduledoc """
  Where a finished review run leaves its task.

  The findings are recorded and, while any of them is waiting on a human, the
  task stays at review: the reviewer recommends and a person decides, so a pass
  that read the change well enough to conclude something still moves nothing.

  A pass that leaves nothing to decide is the exception. No findings, or every
  one of them fixed or already dismissed, is exactly what `send_to_qa/1` would
  let through, and parking a human in front of an empty panel only to have them
  press the button is not a decision. So it goes on to QA by itself - on the
  first pass or on a re-review that found the engineer fixed everything. A
  message the human queued for the reviewer holds it here: they have something
  more to say to this stage.

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
        advance(run)

      nil ->
        fail(run, "The reviewer did not write #{report_file(task)}.")
    end
  end

  # `send_to_qa/1` is the one place that decides whether a review is closed, so
  # it is asked rather than restated here; a refusal is a review still open.
  defp advance(%Run{pending_chat: nil} = run) do
    case Pipeline.send_to_qa(run) do
      {:ok, %Run{} = sent} -> sent
      {:error, _still_open} -> run
    end
  end

  defp advance(%Run{} = run), do: run

  defp report_file(%Task{issue: %Issue{identifier: identifier}}), do: "reviews/#{identifier}.json"

  defp fail(%Run{} = run, error) do
    {:ok, failed} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{failed | task: run.task, role: run.role}
  end
end
