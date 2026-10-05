defmodule Rail.Pipeline.Utils.QaRunFinished do
  @moduledoc """
  Where a finished QA run leaves its task.

  The findings are already rows, each saved with its evidence as QA found it, and
  while any of them is waiting on a human the task stays at QA: QA reports and a
  person decides, so a pass that drove the whole application still moves nothing.

  A pass that leaves nothing to decide is the exception. No findings, or every
  one of them fixed or already dismissed, is exactly what `send_to_demo/1` would
  let through, so it goes on to demo by itself - on the first pass or on a
  re-test that found the engineer fixed everything. A message the human queued
  for QA holds it here: they have something more to say to this stage.

  What a QA run can get wrong is exiting cleanly without saving a verdict, which
  is how a pass says it finished, and that is recorded on the run.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaReport
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo

  @doc "Finishes `run` as the QA stage."
  def qa_run_finished(%Run{} = run, _opts) do
    case run.task |> Repo.preload(:issue) |> Pipeline.read_qa_report() do
      %QaReport{} -> advance(run)
      nil -> fail(run, "The QA agent did not save a verdict.")
    end
  end

  # `send_to_demo/1` is the one place that decides whether QA is closed, so it
  # is asked rather than restated here; a refusal is QA still open.
  defp advance(%Run{pending_chat: nil} = run) do
    case Pipeline.send_to_demo(run) do
      {:ok, %Run{} = sent} -> sent
      {:error, _still_open} -> run
    end
  end

  defp advance(%Run{} = run), do: run

  defp fail(%Run{} = run, error) do
    {:ok, failed} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{failed | task: run.task, role: run.role}
  end
end
