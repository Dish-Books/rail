defmodule Rail.Pipeline.Actions.SkipToReadyToMerge do
  @moduledoc """
  Action to skip a parked gate stage directly to `ready_to_merge`.
  Allowed only when the task is parked (`awaiting_approval`) at a gate stage (`:review`, `:qa`, `:qa_lead`).
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @gate_stages [:review, :qa, :qa_lead]

  @doc """
  Skips a parked gate stage directly to `ready_to_merge`:
  - Enforces `stage_state == :awaiting_approval`.
  - Enforces `stage in [:review, :qa, :qa_lead]`.
  - Sets `stage: :ready_to_merge`, `stage_state: :awaiting_approval`.
  - Clears `error` and `retry_after`.
  - Broadcasts `pipeline_changed`.
  """
  def skip_to_ready_to_merge(%Scope{} = scope, task_or_id) do
    with :ok <- authorize_scope(scope),
         %Task{} = task <- resolve_task(task_or_id) do
      do_skip_to_ready_to_merge(task)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def skip_to_ready_to_merge(task_or_id) do
    skip_to_ready_to_merge(Scope.for_system(), task_or_id)
  end

  defp authorize_scope(%Scope{system: true}), do: :ok
  defp authorize_scope(%Scope{user: %{}}), do: :ok
  defp authorize_scope(_scope), do: {:error, :not_authorized}

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

  defp resolve_task(%Task{} = task), do: task
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil
end
