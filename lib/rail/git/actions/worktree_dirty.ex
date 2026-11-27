defmodule Rail.Git.Actions.WorktreeDirty do
  @moduledoc false

  import Rail.Git.Utils.WorkTree

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  True when `task`'s checkout has changes nobody has committed.
  """
  def worktree_dirty?(%Task{} = task) do
    case work_tree(task) do
      %{repo: repo, head: head, work: work} ->
        match?({_output, 1}, Tools.run("git", ["diff", "--quiet", head, work], cd: repo, stderr_to_stdout: true))

      nil ->
        false
    end
  end
end
