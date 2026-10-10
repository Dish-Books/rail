defmodule Rail.Git.Actions.ClearCommitIdentity do
  @moduledoc """
  Takes the commit identity `set_commit_identity/1` wrote out of a task's worktree once its turn ends, the
  signing key with it, so the key is on disk only while an agent of the task is working.
  """

  import Rail.Git.Utils.SigningKeyPath

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @keys ["user.name", "user.email", "gpg.format", "user.signingkey", "commit.gpgsign"]

  @doc """
  Removes `task`'s turn identity and signing key. Returns `:ok`, whatever was or was not there to remove.
  """
  def clear_commit_identity(%Task{} = task) do
    path = signing_key_path(task)
    File.rm(path)
    File.rm(path <> ".pub")

    # Without the extension `--worktree` is the clone's own config, which this never wrote to.
    if Task.worktree_present?(task) and worktree_config?(task.worktree_path) do
      # git exits 5 for a key that is not set, which is the same as removed.
      for key <- @keys do
        _unset =
          Tools.run("git", ["config", "--worktree", "--unset", key], cd: task.worktree_path, stderr_to_stdout: true)
      end
    end

    :ok
  end

  defp worktree_config?(worktree_path) do
    match?(
      {"true\n", 0},
      Tools.run("git", ["config", "--get", "extensions.worktreeConfig"], cd: worktree_path, stderr_to_stdout: true)
    )
  end
end
