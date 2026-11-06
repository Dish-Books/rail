defmodule Rail.Git.Utils.DiffSides do
  @moduledoc false

  import Rail.Git.Utils.BranchBase

  alias Rail.Pipeline.Schemas.Task

  @doc """
  The revision each side of `task`'s diff under `filter` is read at: the diff's
  base, and the worktree or the commit itself.
  """
  def diff_sides(%Task{}, :uncommitted), do: {"HEAD", :worktree}
  def diff_sides(%Task{} = task, :branch), do: {branch_base(task), :worktree}
  def diff_sides(%Task{}, {:commit, sha}), do: {"#{sha}^1", sha}
end
