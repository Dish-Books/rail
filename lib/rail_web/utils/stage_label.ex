defmodule RailWeb.Utils.StageLabel do
  @moduledoc """
  The one line that says where a task is and what its run is doing.

  Two things make the sentence: the stage the task sits at, and what the run for
  it says about itself. Neither is enough alone: "Plan" does not say whether
  anyone is waiting, and `:done` does not say done with what.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.FixPlan
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

  # Finalize waits on people, not on the run, so a run a comment resumed there does not change what it says.
  def stage_label(%Task{stage: :finalize} = task, _run), do: task |> Task.finalize_state() |> finalize_label()

  # A split parent's work is its children's, so all it says of itself is that its plan was approved.
  def stage_label(%Task{stage: :split}, _run), do: "Plan approved"

  # A child of a split with no run is not next in line while a sibling it builds on is unmerged, and
  # never starts while one is canceled. Read only where the page loaded the parent's children.
  def stage_label(%Task{runs: [], parent_task: %Task{children: [_first | _rest] = siblings}} = task, nil) do
    open =
      Enum.filter(
        siblings,
        &(&1.split_position in task.builds_on and is_nil(&1.merged_at) and is_nil(&1.issue.completed_at) and
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
  def stage_label(%Task{} = task, %Run{status: :waiting_for_usage}), do: "#{Task.stage_label(task)} waiting for usage"

  def stage_label(%Task{} = task, run) do
    case Run.state(run) do
      :queued -> "Queued for #{Task.stage_label(task)}"
      :running -> "#{Task.stage_label(task)} running"
      :waiting -> "#{Task.stage_label(task)} waiting for resources"
      :blocked -> "#{Task.stage_label(task)} needs an answer"
      :failed -> "#{Task.stage_label(task)} failed"
      :stopped -> stopped_label(task, run)
      :done -> approval_label(task)
    end
  end

  @doc "What a task at Finalize says of itself in `state`, `Task.finalize_state/1`'s."
  def finalize_label(:not_ready), do: "Ready to finalize"
  def finalize_label(:ready), do: "Ready for tech lead"
  def finalize_label(:merging), do: "Merging"
  def finalize_label(:refused), do: "Merge refused"
  def finalize_label(:merged), do: "Merged"

  @doc """
  What the human is being asked to read, for a stage that has finished.

  Public because `child_status.ex` reads it, so the task page and the split
  board name the errand alike.
  """
  def approval_label(%Task{stage: :plan} = task) do
    cond do
      waiting_on_pick?(task) -> "Pick a design"
      match?(%Task{issue: %Issue{}}, task) and Issue.skips_step?(task.issue, :architect) -> "Review the ticket"
      true -> "Review the plan"
    end
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

  @doc """
  True when `task` is at a custom stage whose agent has stopped with its file saved, so the file waits on a person's
  Approve.
  """
  def custom_stage_waiting?(%Task{stage: :custom} = task, run) do
    Run.state(run) == :stopped and Enum.any?(Pipeline.read_stage_outputs(task), &(&1.name == task.custom_stage))
  end

  def custom_stage_waiting?(_task, _run), do: false

  @doc "True when `task` has design options saved and none of them picked yet."
  def waiting_on_pick?(%Task{} = task) do
    match?(%{options: [_first | _rest], picked: nil}, Pipeline.read_design(task, pages: false))
  end

  @doc """
  True when `task`'s fix round has a saved plan waiting on a person: approvable, or out of date after a ruling changed.
  """
  def fix_plan_waiting?(%Task{issue: %Issue{}} = task) do
    # Up next asks this of every row, so the findings are read only for a saved plan whose rulings count.
    case Pipeline.read_fix_plan(task) do
      %FixPlan{plan: plan, approved_at: nil} = fix_plan when is_binary(plan) ->
        findings = if task.stage == :review, do: Pipeline.list_findings(task), else: []
        FixPlan.state(fix_plan, task, findings) in [:waiting, :outdated]

      _none_or_settled ->
        false
    end
  end

  def fix_plan_waiting?(%Task{}), do: false

  # A custom stage moves on only by approval, so its stopped agent waits on a person either way.
  defp stopped_label(%Task{stage: :custom} = task, run) do
    if custom_stage_waiting?(task, run), do: "Review #{task.custom_stage}", else: "#{task.custom_stage} needs you"
  end

  defp stopped_label(%Task{} = task, _run), do: "#{Task.stage_label(task)} stopped"

  # Read only off a task whose issue is loaded, which names the review file.
  defp review_finished?(%Task{issue: %Issue{}} = task) do
    case Pipeline.read_review(task) do
      [] -> false
      passes -> List.last(passes).finished_at != nil
    end
  end

  defp review_finished?(%Task{}), do: false
end
