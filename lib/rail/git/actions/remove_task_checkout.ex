defmodule Rail.Git.Actions.RemoveTaskCheckout do
  @moduledoc false

  import Rail.Git.Utils.WithCloneLock

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project

  @doc """
  Removes `task`'s checkout: its own clone is deleted, and a worktree is removed from the project's clone along with
  its branch there. Returns `:ok`.
  """
  def remove_task_checkout(%Project{clone_path: clone_path}, %Task{worktree_path: path, worktree_name: branch})
      when is_binary(path) do
    File.rm_rf!(path <> ".new")

    if File.dir?(Path.join(path, ".git")) do
      # Under the lock a .env save takes, so none writes into a clone half gone.
      with_clone_lock(clone_path, fn -> File.rm_rf!(path) end)
      # The branch's folder goes too, once nothing else is in it.
      _kept_unless_empty = File.rmdir(Path.dirname(path))
    else
      _removed = Git.remove_worktree(clone_path, path)
      if is_binary(branch) and branch != "", do: Git.delete_branch(clone_path, branch)
    end

    :ok
  end
end
