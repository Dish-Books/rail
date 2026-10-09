defmodule Rail.Mcp.Utils.RunToolSaveDemoTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolSaveDemo

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Demo
  alias Rail.Pipeline.Schemas.Task

  setup do
    scratch = Path.join(System.tmp_dir!(), "rt_save_demo_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)

    # A task always has a worktree path, though its directory may be gone.
    worktree = Path.join(scratch, "worktree")
    %{task: %Task{id: "tsk_rt_demo", scratch_path: scratch, worktree_path: worktree, issue: %Issue{identifier: "RTD-1"}}}
  end

  test "a good save is receipted by its title", %{task: task} do
    assert {:ok, "Write-up saved: One round."} =
             run_tool_save_demo(task, %{"title" => "One round", "summary" => "Shown.", "video" => "x"}, [])

    assert %Demo{title: "One round"} = Pipeline.read_demo(task)
  end

  test "a refusal is passed back as the changeset", %{task: task} do
    assert {:error, %Ecto.Changeset{valid?: false}} = run_tool_save_demo(task, %{"title" => "One round"}, [])
  end
end
