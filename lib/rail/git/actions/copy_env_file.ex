defmodule Rail.Git.Actions.CopyEnvFile do
  @moduledoc false

  import Rail.Git.Utils.WithCloneLock
  import Rail.Git.Utils.WriteEnvBlock

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project

  @doc """
  Gives `task`'s checkout the project's `.env`, once its setup script has succeeded.
  Returns `:ok` or `{:error, message}` naming the file that could not be read or written.
  """
  # Under the lock a save takes, so whichever of the two finishes last leaves the newest file.
  def copy_env_file(%Project{clone_path: clone} = project, %Task{} = task) do
    case with_clone_lock(clone, fn -> write_env_block(project, task) end) do
      {:error, :not_running} -> {:error, "#{Path.join(task.worktree_path, ".env")}: the task's sandbox is not running"}
      written -> written
    end
  end
end
