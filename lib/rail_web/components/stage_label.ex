defmodule RailWeb.Components.StageLabel do
  @moduledoc """
  The one line that says where a task is and what its run is doing.

  Two things make the sentence: the stage the task sits at, and what the run for
  it says about itself. Neither is enough alone — "Review" does not say whether
  anyone is waiting, and `:done` does not say done with what.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Runs.Schemas.Run

  @doc """
  Labels `task` with what `run` is doing.

  `run` may be `nil`, which reads as a stage that has not started.
  """
  def stage_label(task, run)

  def stage_label(nil, _run), do: "Waiting on you"

  def stage_label(%Task{is_rebasing: true} = task, run), do: rebase_label(task, run)

  def stage_label(%Task{stage: stage} = task, run) do
    case Run.state(run) do
      :queued -> queued_label(task, stage)
      :running -> "#{Task.stage_label(stage)} running#{cycle(task)}"
      :blocked -> "#{Task.stage_label(stage)} needs an answer"
      :failed -> "#{Task.stage_label(stage)} failed"
      :stopped -> "#{Task.stage_label(stage)} stopped#{cycle(task)}"
      :done -> done_label(task, stage)
    end
  end

  defp rebase_label(%Task{} = task, run) do
    case Run.state(run) do
      :running -> "Rebasing the branch"
      :blocked -> "Rebase needs an answer"
      :failed -> "Rebase failed"
      :stopped -> "Rebase stopped"
      _queued_or_done -> queued_rebase_label(task)
    end
  end

  defp queued_rebase_label(%Task{}), do: "Queued to rebase"

  defp queued_label(%Task{} = task, stage) do
    if Task.conflicted?(task) do
      "Conflicts - needs a rebase"
    else
      "Queued for #{Task.stage_label(stage)}#{cycle(task)}"
    end
  end

  defp done_label(%Task{} = task, stage) do
    if Task.conflicted?(task), do: "Conflicts - needs a rebase", else: approval_label(stage)
  end

  defp approval_label(:product), do: "Review the ticket"
  defp approval_label(:design), do: "Review the design"
  defp approval_label(:architect), do: "Review the plan"
  defp approval_label(:engineer), do: "Ready to send to review"
  defp approval_label(:review), do: "Review needs your call"
  defp approval_label(stage) when stage in [:qa, :qa_lead], do: "QA needs your call"
  defp approval_label(:demo), do: "Review the demo"
  defp approval_label(:ready_to_merge), do: "Ready to merge"
  defp approval_label(_other), do: "Waiting on you"

  # Rework only means something once the engineer has had the change: before that
  # there is nothing to have sent back.
  defp cycle(%Task{rework_cycles: cycles} = task) when is_integer(cycles) and cycles > 0 do
    if Task.before?(task.stage, :engineer) do
      ""
    else
      " · rework #{cycles} of #{(task.rework_budget_base || 0) + 5}"
    end
  end

  defp cycle(%Task{}), do: ""
end
