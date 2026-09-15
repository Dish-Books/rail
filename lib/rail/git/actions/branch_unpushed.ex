defmodule Rail.Git.Actions.BranchUnpushed do
  @moduledoc false

  alias Rail.Tools

  @doc """
  True when the branch has commits the remote has not been told about.

  A branch with no upstream at all counts: it has never been pushed, so whatever
  is on it is only here. This is what makes a push that failed recoverable — the
  commit was made, and the only thing left outstanding says so.
  """
  def branch_unpushed?(worktree_path) when is_binary(worktree_path) do
    case Tools.run("git", ["rev-list", "--count", "@{upstream}..HEAD"],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output) != "0"
      _no_upstream -> true
    end
  end
end
