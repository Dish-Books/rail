defmodule Rail.Mcp.Utils.RunToolSavePlanTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolSavePlan

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  setup do
    scratch = Path.join(System.tmp_dir!(), "rt_save_plan_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)

    %{task: %Task{id: "tsk_rt_plan", scratch_path: scratch, issue: %Issue{identifier: "RTP-1"}}}
  end

  test "a good save is receipted", %{task: task} do
    assert {:ok, "Plan saved. " <> _rest} = run_tool_save_plan(task, %{"plan" => "## Implementation plan\n\nDo it."}, [])
    assert Pipeline.read_plan(task) =~ "Do it."
  end

  test "a refusal is passed back as the changeset", %{task: task} do
    assert {:error, %Ecto.Changeset{valid?: false}} = run_tool_save_plan(task, %{}, [])
  end
end
