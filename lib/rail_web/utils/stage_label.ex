defmodule RailWeb.Utils.StageLabel do
  @moduledoc """
  The one line that says where a task is and what its run is doing.

  Two things make the sentence: the stage the task sits at, and what the run for
  it says about itself. Neither is enough alone: "Plan" does not say whether
  anyone is waiting, and `:done` does not say done with what.
  """

  alias Rail.Pipeline
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

  # Read off its status before the state it shares with a run waiting for a sandbox.
  def stage_label(%Task{stage: stage}, %Run{status: :waiting_for_usage}),
    do: "#{Task.stage_label(stage)} waiting for usage"

  def stage_label(%Task{stage: stage} = task, run) do
    case Run.state(run) do
      :queued -> "Queued for #{Task.stage_label(stage)}"
      :running -> "#{Task.stage_label(stage)} running"
      :waiting -> "#{Task.stage_label(stage)} waiting for resources"
      :blocked -> "#{Task.stage_label(stage)} needs an answer"
      :failed -> "#{Task.stage_label(stage)} failed"
      :stopped -> "#{Task.stage_label(stage)} stopped"
      :done -> approval_label(task)
    end
  end

  @doc """
  What the human is being asked to read, for a stage that has finished.

  Public because the overview asks the same question from the other side - a
  card that says "Review ticket" while the task page says "Review the findings"
  is two answers to one question, and the reader has to open the task to find
  out which is right.
  """
  def approval_label(%Task{stage: :plan} = task) do
    if waiting_on_pick?(task), do: "Pick a design", else: "Review the plan"
  end

  def approval_label(%Task{stage: :engineer}), do: "Review the diff"
  def approval_label(%Task{stage: :review}), do: "Review the findings"
  def approval_label(%Task{stage: :qa}), do: "Review the QA report"
  def approval_label(%Task{stage: :demo}), do: "Watch the demo"
  def approval_label(%Task{}), do: "Waiting on you"

  @doc "True when `task` has design options saved and none of them picked yet."
  def waiting_on_pick?(%Task{} = task) do
    match?(%{options: [_first | _rest], picked: nil}, Pipeline.read_design(task, pages: false))
  end
end
