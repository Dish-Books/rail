defmodule Rail.Git.Actions.ListBranchPaths do
  @moduledoc false

  import Rail.Git.Utils.BranchBase
  import Rail.Git.Utils.WorkTree

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  The files among `paths` that `task`'s branch changed since it forked, committed or not, as the Diff item's branch view
  shows them, as a `MapSet`, or nil when there is no repository to ask or git cannot read it.
  """
  def list_branch_paths(%Task{worktree_path: nil}, _paths), do: nil
  def list_branch_paths(%Task{}, []), do: MapSet.new()

  def list_branch_paths(%Task{} = task, paths) when is_list(paths) do
    with %{repo: repo, work: work} = work_tree <- work_tree(task),
         {output, 0} <-
           Tools.run("git", ["diff", "--name-only", "-z", branch_base(task, work_tree), work, "--" | paths],
             cd: repo,
             stderr_to_stdout: true
           ) do
      MapSet.new(String.split(output, <<0>>, trim: true))
    else
      _unreadable -> nil
    end
  end
end
