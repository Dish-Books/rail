defmodule Rail.Git.Actions.ListBranchPaths do
  @moduledoc false

  import Rail.Git.Utils.BranchBase
  import Rail.Git.Utils.UntrackedPaths

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  The files among `paths` that `task`'s branch changed since it forked, committed or not, as the Diff item's branch view
  shows them, as a `MapSet`, or nil when there is no worktree to ask or git cannot read it.
  """
  def list_branch_paths(%Task{worktree_path: nil}, _paths), do: nil
  def list_branch_paths(%Task{}, []), do: MapSet.new()

  def list_branch_paths(%Task{worktree_path: worktree_path} = task, paths) when is_list(paths) do
    if File.dir?(worktree_path) do
      case Tools.run("git", ["diff", "--name-only", "-z", branch_base(task), "--" | paths],
             cd: worktree_path,
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          untracked = Enum.filter(untracked_paths(worktree_path), &(&1 in paths))
          MapSet.new(String.split(output, <<0>>, trim: true) ++ untracked)

        {_output, _code} ->
          nil
      end
    end
  end
end
