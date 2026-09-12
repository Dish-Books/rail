defmodule Rail.Pipeline.Utils.EngineerRunFinished do
  @moduledoc """
  Where a finished engineer run leaves its task.

  The engineer produces no artifact Rail reads, so its own word is the signal: it
  gets here only once it has said `VERDICT: DONE`, and that hands what is in the
  worktree to review. A demo recorded against the old tree is evidence of a build
  that no longer exists, so it is re-checked on the way.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Runs.Schemas.Run

  @doc "Finishes `run` as the engineer stage."
  def engineer_run_finished(%Run{task: %Task{} = task} = run, opts) do
    Pipeline.refresh_demo_freshness(task, opts)
    Pipeline.enter_stage(task, :review, opts)
    run
  end
end
