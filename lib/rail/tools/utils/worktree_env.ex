defmodule Rail.Tools.Utils.WorktreeEnv do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project

  @doc """
  Returns the variables that tell anything run in `task`'s checkout which ports are its own and where its project's
  clone is. Empty before the task has a slot. Requires `project` loaded.
  """
  def worktree_env(%Task{worktree_slot: slot, project: %Project{clone_path: clone_path}} = task) when is_integer(slot) do
    %{
      "RAIL_WORKTREE_SLOT" => Integer.to_string(slot),
      "RAIL_PORT_BASE" => Integer.to_string(Task.port_base(task)),
      "RAIL_CLONE_PATH" => clone_path
    }
  end

  def worktree_env(%Task{worktree_slot: nil}), do: %{}
end
