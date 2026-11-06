defmodule Rail.Pipeline.Utils.CustomStageRunFinished do
  @moduledoc """
  Where a finished custom stage turn leaves its task: at the stage, whether or not it saved its file. Like Plan, the
  stage moves on only when a person approves what it saved, so its run stays open for the messages before that.
  """

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  @doc "Finishes `run` as a custom stage: `{:open, run}`, with nothing moved."
  def custom_stage_run_finished(%Run{task: %Task{}} = run, _opts), do: {:open, run}
end
