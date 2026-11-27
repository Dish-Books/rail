defmodule Rail.Git.Actions.ListChangedPaths do
  @moduledoc false

  import Rail.Git.Utils.WorkTree

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  Every path in `task`'s checkout that differs from its branch's head, changed, deleted or untracked, sorted.
  """
  def list_changed_paths(%Task{} = task) do
    with %{repo: repo, head: head, work: work} <- work_tree(task),
         {output, 0} <- Tools.run("git", ["diff", "--name-only", "-z", head, work], cd: repo, stderr_to_stdout: true) do
      output |> String.split(<<0>>, trim: true) |> Enum.sort()
    else
      _unreadable -> []
    end
  end
end
