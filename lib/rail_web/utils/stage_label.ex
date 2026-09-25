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

  # No role runs at merged, so there is no run to say anything; the task is done.
  def stage_label(%Task{stage: :merged}, _run), do: "Merged"

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

  @doc """
  What the human is being asked to read, for a stage that has finished.

  Public because the overview asks the same question from the other side - a
  card that says "Review ticket" while the task page says "Review the findings"
  is two answers to one question, and the reader has to open the task to find
  out which is right.
  """
  def approval_label(:product), do: "Review the ticket"
  def approval_label(:design), do: "Review the designs"
  def approval_label(:architect), do: "Review the plan"
  def approval_label(:engineer), do: "Review the diff"
  def approval_label(:review), do: "Review the findings"
  def approval_label(:qa), do: "Review the QA report"
  def approval_label(:demo), do: "Watch the demo"
  def approval_label(_other), do: "Waiting on you"
end
