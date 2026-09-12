defmodule Rail.Pipeline.Utils.ReviewRunFinished do
  @moduledoc """
  Where a finished review run leaves its task.

  Review is a gate: a pass sends the change on to QA, changes requested send it
  back to the engineer.
  """

  import Rail.Pipeline.Utils.GateOutcome

  alias Rail.Runs.Schemas.Run

  @doc "Finishes `run` as the review stage."
  def review_run_finished(%Run{} = run, opts), do: gate_outcome(run, :qa, opts)
end
