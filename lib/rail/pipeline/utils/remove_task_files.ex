defmodule Rail.Pipeline.Utils.RemoveTaskFiles do
  @moduledoc """
  Removes what a task keeps on disk: its checkout, its scratch folder and the
  databases its worktree's setup made.
  """

  import Rail.Pipeline.Utils.DropWorktreeDatabases

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  Removes `task`'s checkout, scratch folder and worktree databases, whichever of them exist.
  """
  def remove_task_files(%Task{} = task) do
    project = Repo.get(Project, task.project_id)
    drop_worktree_databases(task)

    if project do
      if is_binary(task.worktree_path) and task.worktree_path != "" and is_binary(project.clone_path),
        do: Git.remove_task_checkout(project, task)

      remove_scratch_files(task)
    end

    :ok
  end

  defp remove_scratch_files(%Task{scratch_path: scratch_dir}) do
    if is_binary(scratch_dir) and File.exists?(scratch_dir) do
      File.rm_rf!(scratch_dir)
    end
  end
end
