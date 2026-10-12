defmodule RailWeb.Utils.RoleStatusLabel do
  @moduledoc """
  The line under a role's name on the task page: what that role is doing.

  `StageLabel` says this for the whole task, so it names the stage; a role tab
  already carries the name, so this says only the doing.
  """

  import RailWeb.Utils.StageLabel, only: [approval_label: 1]

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role

  @doc """
  What `run` says `role` is doing on `task`. A `nil` run reads as not started.

  Only the role for the stage the task sits at can be waiting on a human, so it
  is the only one whose finished run says what to go and read.
  """
  def role_status_label(role, run, task)

  def role_status_label(%Role{}, nil, %Task{}), do: "not started"
  def role_status_label(%Role{}, %Run{status: :waiting_for_usage}, %Task{}), do: "waiting for usage"

  # A fix round reads as where its plan stands until it is approved, then as fixing while the engineer works.
  def role_status_label(%Role{stage: :review_lead} = role, %Run{} = run, %Task{stage: stage, issue: %Issue{}} = task)
      when stage in [:review, :finalize, :merged] do
    case Pipeline.read_fix_plan(task) do
      %FixPlan{} = fix_plan -> fix_round_label(Run.state(run), fix_plan, task) || label(role, run, task)
      nil -> label(role, run, task)
    end
  end

  def role_status_label(%Role{} = role, %Run{} = run, %Task{} = task), do: label(role, run, task)

  defp label(%Role{stage: role_stage}, %Run{} = run, %Task{stage: stage} = task) do
    case {Run.state(run), role_stage == Task.role_stage(stage)} do
      {:done, true} -> waiting_label(task)
      {state, _at_its_stage} -> label(state)
    end
  end

  defp fix_round_label(run_state, %FixPlan{round: round} = fix_plan, %Task{} = task) do
    case {run_state, FixPlan.state(fix_plan, task, Pipeline.list_findings(task))} do
      {:done, :waiting} ->
        "fix plan to approve"

      {:done, :outdated} ->
        "fix plan out of date"

      {working, :writing} when working in [:running, :waiting] ->
        "fix round #{round} · writing the fix plan"

      {working, _saved} when working in [:running, :waiting] and fix_plan.approved_at == nil ->
        "fix round #{round} · revising the fix plan"

      {working, :approved} when working in [:running, :waiting] ->
        if fixing?(task), do: "fix round #{round} · fixing"

      {stalled, plan_state} when stalled in [:failed, :stopped] and plan_state in [:writing, :revising] ->
        "fix round #{round} · stopped"

      _other ->
        nil
    end
  end

  # The fix round works on the commit the round before it read; once its fix is committed, the next round has begun.
  defp fixing?(%Task{} = task) do
    case Pipeline.read_review(task) do
      [] ->
        false

      passes ->
        Task.worktree_present?(task) and List.last(passes).head == Git.branch_fingerprint(task.worktree_path)[:head_sha]
    end
  end

  defp label(:running), do: "in progress"
  defp label(:waiting), do: "waiting for resources"
  defp label(:blocked), do: "needs an answer"
  defp label(:failed), do: "failed"
  defp label(:stopped), do: "stopped"
  defp label(:done), do: "done"

  # The tab and the header answer the same question, the tab in lower case.
  defp waiting_label(%Task{stage: :plan} = task), do: task |> approval_label() |> String.downcase()
  defp waiting_label(%Task{stage: :review} = task), do: task |> approval_label() |> String.downcase()
  # Finalize has a tab of its own, so the review behind it is simply done.
  defp waiting_label(%Task{stage: :finalize}), do: "done"

  defp waiting_label(%Task{}), do: "needs review"
end
