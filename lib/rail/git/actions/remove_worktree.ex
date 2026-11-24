defmodule Rail.Git.Actions.RemoveWorktree do
  @moduledoc false

  import Rail.Git.Utils.WithCloneLock

  alias Rail.Tools

  @doc """
  Removes a checkout of `repo_path`'s: a clone of its own is deleted, and a worktree is removed and pruned.
  """
  def remove_worktree(repo_path, worktree_path, opts \\ []) when is_binary(repo_path) and is_binary(worktree_path) do
    force? = Keyword.get(opts, :force, true)
    with_clone_lock(repo_path, fn -> remove(repo_path, worktree_path, force?) end)
  end

  # A worktree's .git is a file pointing into the clone, so a .git folder is a clone of its own.
  defp remove(repo_path, worktree_path, force?) do
    if File.dir?(Path.join(worktree_path, ".git")) and Path.expand(worktree_path) != Path.expand(repo_path) do
      File.rm_rf!(worktree_path)
      :ok
    else
      remove_registered(repo_path, worktree_path, force?)
    end
  end

  defp remove_registered(repo_path, worktree_path, force?) do
    result =
      if File.dir?(worktree_path) do
        args =
          if force? do
            ["worktree", "remove", "--force", worktree_path]
          else
            ["worktree", "remove", worktree_path]
          end

        Tools.run("git", args, cd: repo_path, stderr_to_stdout: true)
      else
        {"", 0}
      end

    Tools.run("git", ["worktree", "prune"], cd: repo_path, stderr_to_stdout: true)

    case result do
      {_out, 0} ->
        :ok

      {output, _code} ->
        if File.dir?(worktree_path) do
          {:error, String.trim(output)}
        else
          :ok
        end
    end
  end
end
