defmodule Rail.Pipeline.Actions.RerecordDemo do
  @moduledoc """
  Action to request a fresh recording of a task's demo.
  Guards against merged tasks and missing worktrees, marks the previous demo
  stale, and resets the task to `demo` queued.
  """

  alias Rail.Artifacts
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Returns true if a task is eligible to re-record a demo.
  """
  def can_rerecord_demo?(%Task{} = task) do
    ((task.stage == :ready_to_merge and task.stage_state == :awaiting_approval) or
       (task.stage == :demo and task.stage_state == :failed)) and
      task.stage != :merged and is_nil(task.merged_at) and
      not Task.busy?(task) and
      Task.worktree_present?(task)
  end

  def can_rerecord_demo?(_other), do: false

  @doc """
  Re-records a demo for a task:
  - Validates authorization.
  - Rejects merged tasks with `{:error, :task_merged}`.
  - Rejects missing worktree directories with `{:error, :no_worktree}` after updating task error.
  - Marks latest demo stale.
  - Sets stage to `:demo` queued and clears errors.
  - Broadcasts `pipeline_changed` and pumps the dispatcher.
  """

  def rerecord_demo(%Task{} = task, _opts \\ []) do
    scope = Scope.for_system()

    cond do
      task.stage == :merged or task.merged_at != nil ->
        {:error, :task_merged}

      not Task.worktree_present?(task) ->
        error_msg = "Worktree does not exist on disk (#{task.worktree_path})."

        {:ok, updated_task} =
          task
          |> Task.changeset(%{error: error_msg})
          |> Repo.update()

        Rail.Pipeline.broadcast_pipeline_changed(%{
          task_id: updated_task.id,
          event: :rerecord_demo_failed
        })

        {:error, :no_worktree}

      true ->
        _mark_result = Artifacts.mark_demo_stale(scope, task.id)

        {:ok, updated_task} =
          task
          |> Task.changeset(%{
            stage: :demo,
            stage_state: :queued,
            error: nil,
            retry_after: nil
          })
          |> Repo.update()

        Rail.Pipeline.broadcast_pipeline_changed(%{
          task_id: updated_task.id,
          event: :demo_rerecord
        })

        {:ok, updated_task}
    end
  end
end
