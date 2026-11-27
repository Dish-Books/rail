defmodule Rail.Git.Actions.RemoveTaskCheckout do
  @moduledoc false

  import Rail.Git.Utils.WithCloneLock

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  @doc """
  Removes `task`'s repository, its sandbox with the checkout on its disk, and any checkout on Rail's disk: its own
  clone is deleted, and a worktree of the project's clone is removed from it along with its branch there. Returns `:ok`.
  """
  def remove_task_checkout(%Project{clone_path: clone_path}, %Task{worktree_path: path, worktree_name: branch} = task)
      when is_binary(path) do
    repo = Task.repo_path(task)
    :ok = Tools.end_task_sandbox(task)
    Enum.each([path <> ".new", repo <> ".new"], &File.rm_rf!/1)
    _forgotten = :persistent_term.erase({Git, :synced, task.id})

    # Under the lock a .env save takes, so none writes into a checkout half gone.
    with_clone_lock(clone_path, fn -> File.rm_rf!(repo) end)

    # A task made before tasks had clones of their own is a worktree of the project's clone, there or deleted.
    if String.starts_with?(Path.expand(path), Path.expand(".worktrees", clone_path) <> "/") do
      _removed = Git.remove_worktree(clone_path, path)
      if is_binary(branch) and branch != "", do: Git.delete_branch(clone_path, branch)
    else
      with_clone_lock(clone_path, fn -> File.rm_rf!(path) end)
      # The branch's folder goes too, once nothing else is in it.
      _kept_unless_empty = File.rmdir(Path.dirname(path))
    end

    :ok
  end
end
