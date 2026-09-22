defmodule Rail.Git.Actions.RebasedOnto do
  @moduledoc false

  alias Rail.Git
  alias Rail.Tools

  @doc """
  True when the worktree at `worktree_path` has no rebase under way and
  `origin/<base_branch>` is part of its history.
  """
  def rebased_onto?(worktree_path, base_branch) when is_binary(worktree_path) and is_binary(base_branch) do
    not Git.rebase_in_progress?(worktree_path) and
      match?(
        {_output, 0},
        Tools.run("git", ["merge-base", "--is-ancestor", "origin/#{base_branch}", "HEAD"],
          cd: worktree_path,
          stderr_to_stdout: true
        )
      )
  end
end
