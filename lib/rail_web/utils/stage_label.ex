defmodule RailWeb.Utils.StageLabel do
  @moduledoc """
  The one line that says where a task is and what its run is doing.

  Two things make the sentence: the stage the task sits at, and what the run for
  it says about itself. Neither is enough alone: "Plan" does not say whether
  anyone is waiting, and `:done` does not say done with what.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role

  @doc """
  Labels `task` with what `run` is doing.

  `run` may be `nil`, which reads as a stage that has not started.
  """
  def stage_label(task, run)

  def stage_label(nil, _run), do: "Waiting on you"

  # No role runs at merged, so there is no run to say anything; the task is done.
  def stage_label(%Task{stage: :merged}, _run), do: "Merged"

  # A split parent's work is its children's, so all it says of itself is that its plan was approved.
  def stage_label(%Task{stage: :split}, _run), do: "Plan approved"

  # A child of a split with no run is not next in line while a sibling it builds on is unmerged, and
  # never starts while one is canceled. Read only where the page loaded the parent's children.
  def stage_label(%Task{runs: [], parent_task: %Task{children: [_first | _rest] = siblings}} = task, nil) do
    open =
      Enum.filter(
        siblings,
        &(&1.split_position in task.builds_on and is_nil(&1.issue.completed_at) and
            &1.issue.state not in [:canceled, :duplicate])
      )

    {canceled, removed} = Task.split_blockers(task, siblings)
    blocked_by = canceled ++ removed

    cond do
      blocked_by != [] -> "Blocked by #{Enum.join(blocked_by, ", ")}"
      open != [] -> "Waiting on #{Enum.map_join(open, ", ", & &1.issue.identifier)}"
      true -> "Queued for #{Task.stage_label(task.stage)}"
    end
  end

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

  Public because `role_status_label.ex` and `child_status.ex` read it, so the task page, the tab and the split
  board name the errand alike.
  """
  def approval_label(%Task{stage: :plan} = task) do
    if waiting_on_pick?(task), do: "Pick a design", else: "Review the plan"
  end

  def approval_label(%Task{stage: :engineer}), do: "Review the diff"

  def approval_label(%Task{stage: :review} = task) do
    if review_finished?(task), do: "Ready to merge", else: "Review"
  end

  def approval_label(%Task{}), do: "Waiting on you"

  @doc """
  True when `task` is at Review with its run done and the review finished, nothing left to rule or fix.
  """
  def ready_to_merge?(%Task{stage: :review} = task, run), do: Run.state(run) == :done and review_finished?(task)
  def ready_to_merge?(_task, _run), do: false

  @doc """
  True when `run` is the Review lead's at a task at Review, done and not ready to merge: a round waiting on a person.
  """
  def review_waiting?(%Task{stage: :review} = task, %Run{role: %Role{stage: :review_lead}} = run),
    do: Run.state(run) == :done and not ready_to_merge?(task, run)

  def review_waiting?(_task, _run), do: false

  @doc "True when `task` has design options saved and none of them picked yet."
  def waiting_on_pick?(%Task{} = task) do
    match?(%{options: [_first | _rest], picked: nil}, Pipeline.read_design(task, pages: false))
  end

  # Read only off a task whose issue is loaded, which names the review file.
  defp review_finished?(%Task{issue: %Issue{}} = task) do
    case Pipeline.read_review(task) do
      [] -> false
      passes -> List.last(passes).finished_at != nil
    end
  end

  defp review_finished?(%Task{}), do: false
end
