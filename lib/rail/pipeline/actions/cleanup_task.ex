defmodule Rail.Pipeline.Actions.CleanupTask do
  @moduledoc """
  Action to clean up task worktrees, branches, and scratch artifacts.
  Releases local disk resources when a task is completed or being torn down.
  """

  import Rail.Pipeline.Utils.ScratchPath

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Cleans up worktree, branch, and scratch artifacts for a task.
  """
  def cleanup_task(scope, task_or_id, opts) when is_list(opts) do
    with :ok <- authorize_scope(scope),
         %Task{} = task <- resolve_task(task_or_id) do
      do_cleanup_task(task, opts)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def cleanup_task(task_or_id, opts) when is_list(opts) do
    cleanup_task(Scope.for_system(), task_or_id, opts)
  end

  def cleanup_task(scope, task_or_id) do
    cleanup_task(scope, task_or_id, [])
  end

  def cleanup_task(task_or_id) do
    cleanup_task(Scope.for_system(), task_or_id, [])
  end

  defp authorize_scope(%Scope{system: true}), do: :ok
  defp authorize_scope(%Scope{user: %{}}), do: :ok
  defp authorize_scope(nil), do: :ok
  defp authorize_scope(_scope), do: {:error, :not_authorized}

  defp do_cleanup_task(%Task{} = task, opts) do
    if Task.busy?(task) do
      {:error, :task_busy}
    else
      execute_cleanup(task, opts)
    end
  end

  defp execute_cleanup(%Task{} = task, opts) do
    project = Repo.get(Project, task.project_id)

    if project do
      remove_worktree_if_present(project, task)
      delete_branch_if_present(project, task)
      remove_scratch_files(project, task, opts)
    end

    Rail.Pipeline.broadcast_pipeline_changed(%{
      task_id: task.id,
      event: :task_cleaned_up
    })

    {:ok, task}
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

  defp remove_scratch_files(project, task, opts) do
    scratch_dir = Keyword.get(opts, :scratch_dir) || scratch_path(project.id, task.id)

    if is_binary(scratch_dir) and File.exists?(scratch_dir) do
      File.rm_rf!(scratch_dir)
    end
  end

  defp resolve_task(%Task{} = task), do: task
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil
end
