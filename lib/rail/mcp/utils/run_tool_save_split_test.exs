defmodule Rail.Mcp.Utils.RunToolSaveSplitTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolSaveSplit

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  # The smallest part of a plan the structure allows, trimmed as a save trims it.
  @part String.trim("""
        ## Implementation plan

        ### Approach

        Build it.

        No diagrams: one module changes.

        ### File-level changes

        - `lib/rail.ex`: builds it.

        ### Verification

        - `lib/rail_test.exs`: covers it.
        """)

  setup do
    scratch = Path.join(System.tmp_dir!(), "rt_save_split_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)

    children = [
      %{"title" => "One", "ticket" => "T1.", "plan" => @part},
      %{"title" => "Two", "ticket" => "T2.", "plan" => @part, "builds_on" => [1]}
    ]

    %{task: %Task{id: "tsk_rt_split", scratch_path: scratch, issue: %Issue{identifier: "RTS-1"}}, children: children}
  end

  test "a complete split saves and says how many children", %{task: task, children: children} do
    assert {:ok, "Split saved into 2 children." <> _rest} = run_tool_save_split(task, %{"children" => children}, [])
    assert %{children: [%{title: "One"}, %{title: "Two"}]} = Pipeline.read_split(task)
  end

  test "an empty list removes it", %{task: task, children: children} do
    {:ok, _saved} = run_tool_save_split(task, %{"children" => children}, [])

    assert {:ok, "Split removed: approval makes one task."} = run_tool_save_split(task, %{"children" => []}, [])
    assert Pipeline.read_split(task) == nil
  end

  test "a child missing its part of the plan is handed back as the changeset naming it", %{
    task: task,
    children: [one, two]
  } do
    assert {:error, %Ecto.Changeset{} = changeset} =
             run_tool_save_split(task, %{"children" => [one, Map.delete(two, "plan")]}, [])

    assert %{children: [%{}, %{plan: ["can't be blank"]}]} = errors_on(changeset)
  end
end
