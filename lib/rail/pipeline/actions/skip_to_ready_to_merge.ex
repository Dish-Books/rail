defmodule Rail.Pipeline.Actions.SkipToReadyToMerge do
  @moduledoc """
  Action to skip a parked gate stage directly to `ready_to_merge`.
  Allowed only when the task is parked (`awaiting_approval`) at a gate stage (`:review`, `:qa`, `:qa_lead`).
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @gate_stages [:review, :qa, :qa_lead]

  @doc """
  Skips a parked gate stage directly to `ready_to_merge`:
  - Enforces `stage_state == :awaiting_approval`.
  - Enforces `stage in [:review, :qa, :qa_lead]`.
  - Sets `stage: :ready_to_merge`, `stage_state: :awaiting_approval`.
  - Clears `error` and `retry_after`.
  - Broadcasts `pipeline_changed`.
  """
  def skip_to_ready_to_merge(%Task{} = task) do
    do_skip_to_ready_to_merge(task)
  end

  defp do_skip_to_ready_to_merge(%Task{stage_state: state}) when state != :awaiting_approval do
    {:error, {:invalid_stage_state, state}}
  end

  defp do_skip_to_ready_to_merge(%Task{stage: stage}) when stage not in @gate_stages do
    {:error, {:invalid_stage, stage}}
  end

  defp do_skip_to_ready_to_merge(%Task{} = task) do
    attrs = %{
      stage: :ready_to_merge,
      stage_state: :awaiting_approval,
      error: nil,
      retry_after: nil
    }

    {:ok, updated_task} =
      task
      |> Task.changeset(attrs)
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :skipped_to_ready_to_merge})

    {:ok, updated_task}
  end
end
