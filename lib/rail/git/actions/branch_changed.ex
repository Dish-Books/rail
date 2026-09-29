defmodule Rail.Git.Actions.BranchChanged do
  @moduledoc false

  import Rail.Git.Utils.BranchBase
  import Rail.Git.Utils.UntrackedPaths

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  True when `load_diff/4`'s branch view would have anything in it, found without
  reading the diff out or highlighting it.
  """
  def branch_changed?(%Task{worktree_path: worktree_path} = task) do
    Task.worktree_present?(task) and
      (tracked_changed?(task) or
         Enum.any?(untracked_paths(worktree_path), &File.regular?(Path.join(worktree_path, &1))))
  end

  # `--quiet` exits 1 for a difference and says nothing else; anything but 0 or 1
  # is a diff that could not be read, which draws nothing either.
  defp tracked_changed?(%Task{worktree_path: worktree_path} = task) do
    match?(
      {_output, 1},
      Tools.run("git", ["diff", "--quiet", branch_base(task)], cd: worktree_path, stderr_to_stdout: true)
    )
  end
end
