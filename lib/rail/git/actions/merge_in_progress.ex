defmodule Rail.Git.Actions.MergeInProgress do
  @moduledoc false

  alias Rail.Tools

  @doc "True when the worktree at `worktree_path` is part way through a merge."
  def merge_in_progress?(worktree_path) when is_binary(worktree_path) do
    match?(
      {_sha, 0},
      Tools.run("git", ["rev-parse", "--quiet", "--verify", "MERGE_HEAD"], cd: worktree_path, stderr_to_stdout: true)
    )
  end
end
