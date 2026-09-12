defmodule Rail.Pipeline.Actions.RerecordDemo do
  @moduledoc """
  Records a task's demo again.

  The previous recording is marked stale rather than deleted — it is still what a
  human saw — and the demo stage is entered afresh. A merged task or a worktree
  that is no longer on disk has nothing to record from.
  """

  import Rail.Pipeline.Utils.StageRun

  alias Rail.Artifacts
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs.Schemas.Run
  alias Rail.Scope

  @doc """
  Returns true if a task is eligible to re-record a demo.
  """
  def can_rerecord_demo?(%Task{stage: stage} = task) when stage in [:ready_to_merge, :demo] do
    is_nil(task.merged_at) and
      not (task |> stage_run() |> Run.running?()) and
      Task.worktree_present?(task)
  end

  def can_rerecord_demo?(_other), do: false

  @doc """
  Re-records a demo for a task:
  Re-records `task`'s demo.
  """
  def rerecord_demo(%Task{} = task, opts \\ []) do
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

        Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :rerecord_demo_failed})

        {:error, :no_worktree}

      true ->
        _mark_result = Artifacts.mark_demo_stale(scope, task.id)
        {:ok, _run} = Pipeline.enter_stage(task, :demo, opts)

        Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :demo_rerecord})

        {:ok, Repo.reload!(task)}
    end
  end
end
