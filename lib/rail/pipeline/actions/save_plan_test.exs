defmodule Rail.Pipeline.Actions.SavePlanTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  setup do
    scratch = Path.join(System.tmp_dir!(), "save_plan_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)

    task = %Task{
      id: "tsk_save_plan_#{System.unique_integer([:positive])}",
      scratch_path: scratch,
      issue: %Issue{identifier: "SVP-1"}
    }

    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task.id}")

    %{task: task}
  end

  test "a plan under the heading is written where read_plan reads it, and broadcast", %{task: %{id: task_id} = task} do
    assert {:ok, "## Implementation plan\n\nExtend the module."} =
             Pipeline.save_plan(task, "## Implementation plan\n\nExtend the module.\n")

    assert Pipeline.read_plan(task) == "## Implementation plan\n\nExtend the module.\n"
    assert_received {:output_saved, ^task_id}
  end

  test "a blank plan, or one without the heading, is refused and leaves the earlier plan", %{task: task} do
    {:ok, _first} = Pipeline.save_plan(task, "## Implementation plan\n\nFirst.")

    assert {:error, blank} = Pipeline.save_plan(task, "   ")
    assert %{plan: ["can't be blank"]} = errors_on(blank)

    assert {:error, unheaded} = Pipeline.save_plan(task, "# Plan\n\nSecond.")
    assert %{plan: ["must open with the `## Implementation plan` heading"]} = errors_on(unheaded)

    assert {:error, listed} = Pipeline.save_plan(task, ["## Implementation plan"])
    assert %{plan: ["is invalid"]} = errors_on(listed)

    assert Pipeline.read_plan(task) == "## Implementation plan\n\nFirst.\n"
  end

  test "a second save replaces the first", %{task: task} do
    {:ok, _first} = Pipeline.save_plan(task, "## Implementation plan\n\nFirst.")
    {:ok, _second} = Pipeline.save_plan(task, "## Implementation plan\n\nSecond.")

    assert Pipeline.read_plan(task) == "## Implementation plan\n\nSecond.\n"
  end
end
