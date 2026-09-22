defmodule Rail.Tools.Utils.WorktreeEnvTest do
  use ExUnit.Case, async: true

  import Rail.Tools.Utils.WorktreeEnv

  alias Rail.Pipeline.Schemas.Task

  test "gives a task with a slot the block of ports that slot owns" do
    assert worktree_env(%Task{worktree_slot: 3}) == %{"RAIL_WORKTREE_SLOT" => "3", "RAIL_PORT_BASE" => "20300"}
  end

  test "says nothing for a task that has no slot yet" do
    assert worktree_env(%Task{worktree_slot: nil}) == %{}
  end
end
