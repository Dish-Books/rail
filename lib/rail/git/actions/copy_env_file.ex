defmodule Rail.Git.Actions.CopyEnvFile do
  @moduledoc false

  import Rail.Git.Utils.WithCloneLock
  import Rail.Git.Utils.WriteEnvBlock

  alias Rail.Projects.Schemas.Project

  @doc """
  Gives the worktree at `worktree_path` the project's `.env`, once its setup script has succeeded.
  Returns `:ok` or `{:error, message}` naming the file that could not be read or written.
  """
  # Under the lock a save takes, so whichever of the two finishes last leaves the newest file.
  def copy_env_file(%Project{clone_path: clone} = project, worktree_path) when is_binary(worktree_path) do
    with_clone_lock(clone, fn -> write_env_block(project, worktree_path) end)
  end
end
