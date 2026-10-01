defmodule Rail.Git.Actions.WorktreeDirty do
  @moduledoc false

  alias Rail.Tools

  @doc """
  True when the worktree has changes nobody has committed.
  """
  def worktree_dirty?(worktree_path) when is_binary(worktree_path) do
    case Tools.run("git", ["status", "--porcelain", "--untracked-files=all"],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output) != ""
      _unreadable -> false
    end
  end
end
