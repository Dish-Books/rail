defmodule Rail.Git.Actions.UpToDateWith do
  @moduledoc false

  alias Rail.Git
  alias Rail.Tools

  @doc """
  True when the worktree at `worktree_path` has no merge under way and
  `origin/<base_branch>` is part of its history.
  """
  def up_to_date_with?(worktree_path, base_branch) when is_binary(worktree_path) and is_binary(base_branch) do
    not Git.merge_in_progress?(worktree_path) and
      match?(
        {_output, 0},
        Tools.run("git", ["merge-base", "--is-ancestor", "origin/#{base_branch}", "HEAD"],
          cd: worktree_path,
          stderr_to_stdout: true
        )
      )
  end
end
