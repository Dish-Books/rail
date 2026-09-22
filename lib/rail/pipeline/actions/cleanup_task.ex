defmodule Rail.Pipeline.Actions.CleanupTask do
  @moduledoc """
  Action to clean up task worktrees, branches, and scratch artifacts.
  Releases local disk resources when a task is completed or being torn down.
  """

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
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
    project = Repo.get(Project, task.project_id)

    if project do
      remove_worktree_if_present(project, task)
      delete_branch_if_present(project, task)
      remove_scratch_files(task)
    end

    mark_cleaned_up(task)
  end

  defp mark_cleaned_up(%Task{cleaned_up_at: nil} = task) do
    # The worktree is gone, so its ports are free and a new one would need setting up.
    task
    |> Task.changeset(%{cleaned_up_at: DateTime.utc_now(), worktree_slot: nil, worktree_setup_at: nil})
    |> Repo.update()
  end

  defp mark_cleaned_up(%Task{} = task), do: {:ok, task}

  defp remove_worktree_if_present(project, task) do
    if is_binary(task.worktree_path) and task.worktree_path != "" and is_binary(project.clone_path) do
      Git.remove_worktree(project.clone_path, task.worktree_path)
    end
  end

  defp delete_branch_if_present(project, task) do
    if is_binary(task.worktree_name) and task.worktree_name != "" and is_binary(project.clone_path) do
      Git.delete_branch(project.clone_path, task.worktree_name)
    end
  end

  defp remove_scratch_files(%Task{scratch_path: scratch_dir}) do
    if is_binary(scratch_dir) and File.exists?(scratch_dir) do
      File.rm_rf!(scratch_dir)
    end
  end
end
