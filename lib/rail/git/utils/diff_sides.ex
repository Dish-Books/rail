defmodule Rail.Git.Utils.DiffSides do
  @moduledoc false

  import Rail.Git.Utils.BranchBase

  alias Rail.Pipeline.Schemas.Task

  @doc """
  The revision each side of `task`'s diff under `filter` is read at, `work_tree` being where its branch stands: the
  diff's base, and the working tree or the commit itself.
  """
  def diff_sides(%Task{}, %{head: head, work: work}, :uncommitted), do: {head, work}
  def diff_sides(%Task{} = task, %{work: work} = work_tree, :branch), do: {branch_base(task, work_tree), work}
  def diff_sides(%Task{}, _work_tree, {:commit, sha}), do: {"#{sha}^1", sha}
end
