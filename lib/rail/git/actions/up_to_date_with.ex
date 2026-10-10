defmodule Rail.Git.Actions.UpToDateWith do
  @moduledoc false

  alias Rail.Tools

  @doc """
  False only when git says `origin/<base_branch>` is not in the history of the worktree's HEAD. One git
  cannot read is taken as up to date, since nothing can be said about it.
  """
  def up_to_date_with?(worktree_path, base_branch) when is_binary(worktree_path) and is_binary(base_branch) do
    not match?(
      {_output, 1},
      Tools.run("git", ["merge-base", "--is-ancestor", "origin/#{base_branch}", "HEAD"],
        cd: worktree_path,
        stderr_to_stdout: true
      )
    )
  end
end
