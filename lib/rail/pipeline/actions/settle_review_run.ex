defmodule Rail.Pipeline.Actions.SettleReviewRun do
  @moduledoc """
  Settles a finished review-stage run.

  Review is a gate: a pass sends the change on to QA, changes requested send it
  back to the engineer, and no clear verdict parks it for a human.
  """

  import Rail.Pipeline.Utils.AdvanceStage
  import Rail.Pipeline.Utils.GateOutcome

  alias Rail.Runs.Schemas.Run

  @doc "Settles the finished review `run` against `outcome`."
  def settle_review_run(%Run{} = run, _outcome \\ %{}, opts \\ []) do
    advance_stage(run, opts, &to_qa/3)
  end

  defp to_qa(task, role_run, _opts), do: gate_outcome(task, role_run, :qa)
end
