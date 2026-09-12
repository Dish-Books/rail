defmodule Rail.Pipeline.Utils.ReviewRunFinished do
  @moduledoc """
  Where a finished review-stage run leaves its task.

  Review is a gate: a pass sends the change on to QA, changes requested send it
  back to the engineer, and no clear verdict parks it for a human.
  """

  import Rail.Pipeline.Utils.AdvanceStage
  import Rail.Pipeline.Utils.GateOutcome

  alias Rail.Runs.Schemas.OsProcess

  @doc "Finishes the review run that `os_process` belonged to."
  def finish_review_run(%OsProcess{} = os_process, _outcome \\ %{}, opts \\ []) do
    advance_stage(os_process, opts, &to_qa/3)
  end

  defp to_qa(task, run, _opts), do: gate_outcome(task, run, :qa)
end
