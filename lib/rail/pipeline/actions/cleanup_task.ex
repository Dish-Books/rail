defmodule Rail.Pipeline.Actions.CleanupTask do
  @moduledoc """
  Action to clean up task worktrees, branches, and scratch artifacts.
  Releases local disk resources when a task is completed or being torn down.
  """

  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.RemoveTaskFiles

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Cleans up worktree, branch, and scratch artifacts for a task, then stamps it
  `cleaned_up_at` so its issue can be started again. The row, its runs and its
  questions are kept as history.

  Every run on the task has to be stopped, not just the one for the stage it sits
  at: the worktree this deletes is the one all of them are working in.
  """
  def cleanup_task(%Task{} = task) do
    task = Repo.preload(task, :runs, force: true)

    if Task.running?(task) do
      {:error, :task_busy}
    else
      execute_cleanup(task)
    end
  end

  defp execute_cleanup(%Task{} = task) do
    remove_task_files(task)
    mark_cleaned_up(task)
  end

  defp mark_cleaned_up(%Task{cleaned_up_at: nil} = task) do
    # The worktree is gone, so its ports are free and a new one would need setting up.
    {:ok, cleaned} =
      task
      |> Task.changeset(%{cleaned_up_at: DateTime.utc_now(), worktree_slot: nil, worktree_setup_at: nil})
      |> Repo.update()

    {:ok, broadcast_pipeline_changed(cleaned)}
  end

  defp mark_cleaned_up(%Task{} = task), do: {:ok, task}
end
