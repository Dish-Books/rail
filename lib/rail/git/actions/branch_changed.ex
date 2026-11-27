defmodule Rail.Git.Actions.BranchChanged do
  @moduledoc false

  import Rail.Git.Utils.BranchBase
  import Rail.Git.Utils.WorkTree

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  True when `load_diff/4`'s branch view would have anything in it, found without
  reading the diff out or highlighting it.
  """
  # `--quiet` exits 1 for a difference and says nothing else; anything but 0 or 1
  # is a diff that could not be read, which draws nothing either.
  def branch_changed?(%Task{} = task) do
    case work_tree(task) do
      %{repo: repo, work: work} = work_tree ->
        match?(
          {_output, 1},
          Tools.run("git", ["diff", "--quiet", branch_base(task, work_tree), work], cd: repo, stderr_to_stdout: true)
        )

      nil ->
        false
    end
  end
end
