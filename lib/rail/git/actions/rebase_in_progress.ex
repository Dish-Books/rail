defmodule Rail.Git.Actions.RebaseInProgress do
  @moduledoc false

  alias Rail.Tools

  @doc "True when the worktree at `worktree_path` is part way through a rebase."
  def rebase_in_progress?(worktree_path) when is_binary(worktree_path) do
    # A worktree's git directory is not `.git` inside it, so git is asked where it is.
    Enum.any?(["rebase-merge", "rebase-apply"], fn name ->
      {path, 0} = Tools.run("git", ["rev-parse", "--git-path", name], cd: worktree_path, stderr_to_stdout: true)
      File.dir?(Path.expand(String.trim(path), worktree_path))
    end)
  end
end
