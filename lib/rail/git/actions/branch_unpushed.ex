defmodule Rail.Git.Actions.BranchUnpushed do
  @moduledoc false

  alias Rail.Tools

  @doc """
  True when HEAD has commits no ref fetched from a remote has: work committed here and not yet pushed.

  A fresh branch Rail made from the default branch has nothing of its own yet, so it is not unpushed for
  having no upstream; one rebased since its push is, since its rewritten commits are only here.
  """
  def branch_unpushed?(worktree_path) when is_binary(worktree_path) do
    case Tools.run("git", ["rev-list", "--count", "HEAD", "--not", "--remotes"],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output) != "0"
      _unreadable -> true
    end
  end
end
