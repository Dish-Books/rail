defmodule Rail.Git.Actions.ConflictedFiles do
  @moduledoc false

  alias Rail.Tools

  @doc "The files in the worktree at `worktree_path` still marked as conflicted."
  def conflicted_files(worktree_path) when is_binary(worktree_path) do
    {output, 0} =
      Tools.run("git", ["diff", "--name-only", "--diff-filter=U"], cd: worktree_path, stderr_to_stdout: true)

    String.split(output, "\n", trim: true)
  end
end
