defmodule Rail.Git.Utils.TaskBranch do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Task

  @doc """
  The name of `task`'s branch: its worktree's name, or its id for a task made before worktrees were named.
  """
  def task_branch(%Task{worktree_name: name}) when is_binary(name), do: name
  def task_branch(%Task{id: id}), do: id
end
