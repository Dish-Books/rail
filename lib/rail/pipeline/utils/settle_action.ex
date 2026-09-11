defmodule Rail.Pipeline.Utils.SettleAction do
  @moduledoc """
  Which settle action a task's run belongs to.

  This is the one place left that matches on `task.stage`. Everything downstream
  of it is per-stage by construction: each stage has its own settle action, and
  none is shared with another.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Returns the `(run, outcome, opts)` function that settles a run started for `task`.

  A rebase is the engineer role on a detour, so it settles as a rebase whatever
  stage the task is parked at — the same rule `start_stage_run` uses to pick the
  engineer role for one.
  """
  def settle_action(%Task{is_rebasing: true}), do: &Pipeline.settle_rebase_run/3
  def settle_action(%Task{stage: :product}), do: &Pipeline.settle_product_run/3
  def settle_action(%Task{stage: :design}), do: &Pipeline.settle_design_run/3
  def settle_action(%Task{stage: :architect}), do: &Pipeline.settle_architect_run/3
  def settle_action(%Task{stage: :engineer}), do: &Pipeline.settle_engineer_run/3
  def settle_action(%Task{stage: :review}), do: &Pipeline.settle_review_run/3
  def settle_action(%Task{stage: :qa}), do: &Pipeline.settle_qa_run/3
  def settle_action(%Task{stage: :qa_lead}), do: &Pipeline.settle_qa_lead_run/3
  def settle_action(%Task{stage: :demo}), do: &Pipeline.settle_demo_run/3
end
