defmodule Rail.Git.Actions.BranchUnpushed do
  @moduledoc false

  import Rail.Git.Utils.WorkTree

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  True when `task`'s branch has commits no ref fetched from a remote has: work committed and not yet pushed.

  A fresh branch Rail made from the default branch has nothing of its own yet, so it is not unpushed for
  having no upstream; one rebased since its push is, since its rewritten commits are only here.
  """
  def branch_unpushed?(%Task{} = task) do
    with %{repo: repo, head: head} <- work_tree(task),
         {output, 0} <- Tools.run("git", ["rev-list", "--count", head, "--not", "--remotes"], cd: repo) do
      String.trim(output) != "0"
    else
      _unreadable -> true
    end
  end
end
