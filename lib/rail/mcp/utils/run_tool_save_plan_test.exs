defmodule Rail.Mcp.Utils.RunToolSavePlanTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolSavePlan

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  # The smallest plan the structure allows: no diagrams, so Approach says why, and no Program design.
  @plan """
  ## Implementation plan

  ### Approach

  Extend the module.

  No diagrams: one module changes.

  ### File-level changes

  - `lib/rail.ex`: extends the module.

  ### Verification

  - `lib/rail_test.exs`: covers the extension.
  """

  setup do
    scratch = Path.join(System.tmp_dir!(), "rt_save_plan_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)

    %{task: %Task{id: "tsk_rt_plan", scratch_path: scratch, issue: %Issue{identifier: "RTP-1"}}, scratch: scratch}
  end

  test "a save with no option says it names none yet", %{task: task} do
    assert {:ok, "Plan saved, written for no design option yet." <> _rest} =
             run_tool_save_plan(task, %{"plan" => @plan}, [])

    assert %{content: @plan, design: nil} = Pipeline.read_plan(task)
  end

  test "a save for a saved option passes the key through and names the option", %{task: task, scratch: scratch} do
    File.mkdir_p!(Path.join(scratch, "design"))

    File.write!(
      Path.join(scratch, "design/manifest.json"),
      ~s({"options": [{"key": "rows", "title": "Charts in the row"}]})
    )

    assert {:ok, "Plan saved for Charts in the row (rows)." <> _rest} =
             run_tool_save_plan(task, %{"plan" => @plan, "design" => "rows"}, [])
  end

  test "a refusal is passed back as the changeset naming the field", %{task: task} do
    assert {:error, %Ecto.Changeset{valid?: false}} = run_tool_save_plan(task, %{}, [])

    assert {:error, %Ecto.Changeset{errors: [design: _no_options]}} =
             run_tool_save_plan(task, %{"plan" => @plan, "design" => "rows"}, [])
  end
end
