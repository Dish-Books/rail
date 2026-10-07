defmodule Rail.Pipeline.Utils.RemoveTaskFiles do
  @moduledoc """
  Removes what a task keeps on disk: its worktree, its branch in the project's
  clone and its scratch folder.
  """

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  Removes `task`'s worktree, branch and scratch folder, whichever of them exist.
  """
  def remove_task_files(%Task{} = task) do
    project = Repo.get(Project, task.project_id)

    if project do
      remove_worktree_if_present(project, task)
      delete_branch_if_present(project, task)
      remove_scratch_files(task)
    end

    :ok
  end

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
