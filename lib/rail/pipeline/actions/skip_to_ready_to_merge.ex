defmodule Rail.Pipeline.Actions.SkipToReadyToMerge do
  @moduledoc """
  Takes a change from a gate straight to the merge on human request.

  The gate is not overruled so much as stood down: a human who has read its
  findings and decided to ship anyway does not need it to agree first. Only a
  gate that has stopped can be skipped — and not only the gate: nothing on the
  task may still be working, because skipping ahead of a run still writing to the
  branch would ship a change nobody has seen whole.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @gate_stages [:review, :qa, :qa_lead]

  @doc """
  Skips the gate `task` is parked at and enters `:ready_to_merge`.
  """
  def skip_to_ready_to_merge(%Task{stage: stage}) when stage not in @gate_stages do
    {:error, {:invalid_stage, stage}}
  end

  def skip_to_ready_to_merge(%Task{} = task) do
    task = Repo.preload(task, :runs)

    if Task.running?(task) do
      {:error, :stage_running}
    else
      enter_ready_to_merge(task)
    end
  end

  defp enter_ready_to_merge(%Task{} = task) do
    {:ok, task} = Pipeline.enter_stage(task, :ready_to_merge)


    {:ok, task}
  end
end
