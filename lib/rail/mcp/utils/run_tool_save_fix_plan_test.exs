defmodule Rail.Mcp.Utils.RunToolSaveFixPlanTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolSaveFixPlan

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @plan "### What changes\n\n#### `nil-crash`\n\nGuard nil.\n\n### File-level changes\n\n#### `lib/a.ex`\n\nFor `nil-crash`.\n\n```elixir sketch\ndef go, do: :ok\n```"

  setup do
    scratch = Path.join(System.tmp_dir!(), "rt_save_fix_plan_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)

    %{
      task: %Task{
        id: "tsk_rt_fix_plan",
        stage: :review,
        scratch_path: scratch,
        worktree_path: Path.join(scratch, "worktree"),
        issue: %Issue{identifier: "RTF-1"}
      }
    }
  end

  test "a saved plan answers with its version and round", %{task: task} do
    File.mkdir_p!(Path.join(task.scratch_path, "fix_plans"))

    File.write!(
      Path.join([task.scratch_path, "fix_plans", "RTF-1.json"]),
      Jason.encode!(%{round: 2, findings: [%{key: "nil-crash", title: "Nil crashes"}], comments: []})
    )

    assert {:ok, "Fix plan saved as version 1 of fix round 2." <> _rest} =
             run_tool_save_fix_plan(task, %{"plan" => @plan, "other" => 1}, [])

    assert {:error, %Ecto.Changeset{}} = run_tool_save_fix_plan(task, %{"plan" => "### What changes"}, [])
  end

  test "a saved plan on a branch that conflicts with the default branch says Rail merges it first", %{
    project: project
  } do
    task = learnings_task(project, "RTF-2", :review)
    # Git is stubbed, so the worktree is only looked for: a plain directory stands in for it.
    worktree_path = Path.join(System.tmp_dir!(), "rail_rtf_wt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(worktree_path)
    on_exit(fn -> File.rm_rf(worktree_path) end)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    stub(Git, :base_status, fn _path, "main" -> %{behind: true, conflicts: ["lib/a.ex", "lib/b.ex"]} end)
    File.mkdir_p!(Path.join(task.scratch_path, "fix_plans"))

    File.write!(
      Path.join([task.scratch_path, "fix_plans", "#{task.issue.identifier}.json"]),
      Jason.encode!(%{round: 2, findings: [%{key: "nil-crash", title: "Nil crashes"}], comments: []})
    )

    assert {:ok, message} = run_tool_save_fix_plan(task, %{"plan" => @plan}, [])

    assert message =~
             "The branch conflicts with the default branch in 2 files, so Rail has the round merge it in first; leave that out of the plan."
  end

  test "with no plan due it says so", %{task: task} do
    assert {:refused, "Nothing saved: no fix plan is due." <> _rest} =
             run_tool_save_fix_plan(task, %{"plan" => @plan}, [])
  end

  test "with nothing to fix it says to end the turn", %{task: task} do
    File.mkdir_p!(Path.join(task.scratch_path, "reviews"))

    File.write!(
      Path.join([task.scratch_path, "reviews", "RTF-1.json"]),
      ~s({"passes": [{"round": 1, "saved_at": "2026-10-14T10:00:00Z", "head": "abc"}]})
    )

    assert {:refused, "Nothing saved: nothing is ruled Fix" <> _rest} =
             run_tool_save_fix_plan(task, %{"plan" => "Nothing to fix.\n\n### What changes"}, [])
  end

  test "a demo asked of a task whose workflow turned it off says the demo is off", %{task: task} do
    task = %{task | issue: %{task.issue | skipped_steps: [:demo]}}

    assert {:refused, "Nothing saved: the demo is off for this task, so leave out `record_demo`."} =
             run_tool_save_fix_plan(task, %{"plan" => @plan, "record_demo" => true}, [])
  end
end
