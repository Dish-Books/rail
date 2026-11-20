defmodule Rail.Tools.Utils.WorktreeEnvTest do
  use ExUnit.Case, async: true

  import Rail.Tools.Utils.WorktreeEnv

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project

  test "gives a task with a slot the block of ports that slot owns and where its project's clone is" do
    task = %Task{worktree_slot: 3, project: %Project{clone_path: "/srv/rail/projects/acme"}}

    assert worktree_env(task) == %{
             "RAIL_WORKTREE_SLOT" => "3",
             "RAIL_PORT_BASE" => "20300",
             "RAIL_CLONE_PATH" => "/srv/rail/projects/acme"
           }
  end

  test "says nothing for a task that has no slot yet" do
    assert worktree_env(%Task{worktree_slot: nil}) == %{}
  end
end
