defmodule RailWeb.Utils.StageLabel do
  @moduledoc """
  The one line that says where a task is and what its run is doing.

  Two things make the sentence: the stage the task sits at, and what the run for
  it says about itself. Neither is enough alone — "Product" does not say whether
  anyone is waiting, and `:done` does not say done with what.
  """

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Labels `task` with what `run` is doing.

  `run` may be `nil`, which reads as a stage that has not started.
  """
  def stage_label(task, run)

  def stage_label(nil, _run), do: "Waiting on you"

  def stage_label(%Task{stage: stage}, run) do
    case Run.state(run) do
      :queued -> "Queued for #{Task.stage_label(stage)}"
      :running -> "#{Task.stage_label(stage)} running"
      :blocked -> "#{Task.stage_label(stage)} needs an answer"
      :failed -> "#{Task.stage_label(stage)} failed"
      :stopped -> "#{Task.stage_label(stage)} stopped"
      :done -> approval_label(stage)
    end
  end

  defp approval_label(:product), do: "Review the ticket"
  defp approval_label(:design), do: "Review the designs"
  defp approval_label(:architect), do: "Review the plan"
  defp approval_label(:engineer), do: "Review the diff"
  defp approval_label(:review), do: "Review the findings"
  defp approval_label(_other), do: "Waiting on you"
end
