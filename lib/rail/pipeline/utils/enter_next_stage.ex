defmodule Rail.Pipeline.Utils.EnterNextStage do
  @moduledoc false

  import Rail.Pipeline.Utils.StartChecks

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Moves `task` on to `stage`, the next of its issue's sequence, and starts it: at Review the agents that check the
  round, and anywhere else the stage's own agent on a clean conversation. Returns `{:ok, run_or_task}`.
  """
  def enter_next_stage(%Task{} = task, :review) do
    {:ok, reviewing} = Pipeline.enter_stage(task, :review, start: false)
    # A round that brought the branch up to date clears its Update, and one that did not may still need it.
    {:ok, reviewing} = Pipeline.check_base(reviewing)
    :ok = start_checks(reviewing)
    {:ok, reviewing}
  end

  def enter_next_stage(%Task{} = task, stage), do: Pipeline.enter_stage(task, stage, fresh: true)
end
