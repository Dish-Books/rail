defmodule Rail.Pipeline.Actions.ApproveStage do
  @moduledoc """
  Approves a task waiting at an approval gate and advances it to the next pipeline stage.
  """

  alias Rail.Pipeline.Dispatcher
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope

  @doc """
  Approves the current stage of a task:
  - Enforces `stage_state == :awaiting_approval` and `stage != :ready_to_merge`.
  - Determines the next stage in pipeline order (respecting `:skip_design`).
  - Sets `stage_state: :queued` (or `:awaiting_approval` if advancing to `:ready_to_merge`).
  - Clears `error` and `retry_after`.
  - Broadcasts `pipeline_changed` and pumps the Dispatcher when queued.
  """
  def approve_stage(%Scope{} = scope, task_or_id, opts) when is_list(opts) do
    with :ok <- authorize_scope(scope),
         %Task{} = task <- resolve_task(task_or_id) do
      do_approve_stage(task, opts)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def approve_stage(%Scope{} = scope, task_or_id) do
    approve_stage(scope, task_or_id, [])
  end

  def approve_stage(task_or_id, opts) when is_list(opts) do
    approve_stage(Scope.for_system(), task_or_id, opts)
  end

  def approve_stage(task_or_id) do
    approve_stage(Scope.for_system(), task_or_id, [])
  end

  defp authorize_scope(%Scope{system: true}), do: :ok
  defp authorize_scope(%Scope{user: %{}}), do: :ok
  defp authorize_scope(_scope), do: {:error, :not_authorized}

  defp do_approve_stage(%Task{stage_state: state}, _opts) when state != :awaiting_approval do
    {:error, {:invalid_stage_state, state}}
  end

  defp do_approve_stage(%Task{stage: :ready_to_merge}, _opts) do
    {:error, :cannot_approve_ready_to_merge}
  end

  defp do_approve_stage(%Task{} = task, opts) do
    next_stage = determine_next_stage(task, opts)

    {stage_state, error} =
      if next_stage == :ready_to_merge do
        {:awaiting_approval, nil}
      else
        case Roles.role_for_stage(task.project_id, next_stage) do
          {:ok, _role} ->
            {:queued, nil}

          _no_role ->
            {:failed, "No role is configured for the #{next_stage} stage"}
        end
      end

    attrs = %{
      stage: next_stage,
      stage_state: stage_state,
      retry_after: nil,
      error: error
    }

    {:ok, updated_task} =
      task
      |> Task.changeset(attrs)
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :stage_approved})

    if stage_state == :queued do
      Dispatcher.pump()
    end

    {:ok, updated_task}
  end

  defp determine_next_stage(%Task{stage: :product} = task, opts) do
    skip_design? = Keyword.get(opts, :skip_design, false)

    if skip_design? do
      :architect
    else
      case Roles.role_for_stage(task.project_id, :design) do
        {:ok, _role} -> :design
        _no_role -> :architect
      end
    end
  end

  defp determine_next_stage(%Task{stage: :design}, _opts), do: :architect
  defp determine_next_stage(%Task{stage: :architect}, _opts), do: :engineer
  defp determine_next_stage(%Task{stage: :engineer}, _opts), do: :review
  defp determine_next_stage(%Task{stage: :review}, _opts), do: :qa
  defp determine_next_stage(%Task{stage: :qa}, _opts), do: :qa_lead

  defp determine_next_stage(%Task{stage: :qa_lead} = task, _opts) do
    case Roles.role_for_stage(task.project_id, :demo) do
      {:ok, _role} -> :demo
      _no_role -> :ready_to_merge
    end
  end

  defp determine_next_stage(%Task{stage: :demo}, _opts), do: :ready_to_merge

  defp resolve_task(%Task{} = task), do: task
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil
end
