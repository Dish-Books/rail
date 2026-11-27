defmodule Rail.Tools.Utils.WorktreeEnv do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Task

  @doc """
  Returns the variables that tell anything run in `task`'s checkout which ports are its own. Empty before the task has
  a slot. A sandbox has no project clone to read: its project's image carries the build cache.
  """
  def worktree_env(%Task{worktree_slot: slot} = task) when is_integer(slot) do
    %{"RAIL_WORKTREE_SLOT" => Integer.to_string(slot), "RAIL_PORT_BASE" => Integer.to_string(Task.port_base(task))}
  end

  def worktree_env(%Task{worktree_slot: nil}), do: %{}
end
