defmodule Rail.Pipeline.Actions.ReadFixPlanTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Task

  setup do
    scratch = Path.join(System.tmp_dir!(), "read_fix_plan_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    %{task: %Task{id: "tsk_read_fix_plan", scratch_path: scratch, issue: %Issue{identifier: "RFP-1"}}}
  end

  test "reads back what was written", %{task: task} do
    File.mkdir_p!(Path.join(task.scratch_path, "fix_plans"))

    File.write!(
      Path.join([task.scratch_path, "fix_plans", "RFP-1.json"]),
      Jason.encode!(%{
        round: 2,
        plan: "### What changes",
        covered_keys: ["nil-crash"],
        covered_comments: 1,
        version: 3,
        saved_at: "2026-10-12T16:42:00.000000Z",
        approved_by: "Michael Kim",
        approved_at: "2026-10-12T16:58:00.000000Z",
        findings: [%{key: "nil-crash", title: "Nil crashes"}],
        comments: [%{number: 1, kind: "diff", place: "a.ex:3", text: "Keep it."}]
      })
    )

    assert %FixPlan{
             round: 2,
             version: 3,
             covered_keys: ["nil-crash"],
             covered_comments: 1,
             approved_by: "Michael Kim",
             approved_at: ~U[2026-10-12 16:58:00.000000Z],
             findings: [%FixPlan.Finding{key: "nil-crash", title: "Nil crashes"}],
             comments: [%FixPlan.Comment{number: 1, kind: :diff, place: "a.ex:3", text: "Keep it."}]
           } = Pipeline.read_fix_plan(task)
  end

  test "no file reads as no plan", %{task: task} do
    assert Pipeline.read_fix_plan(task) == nil
  end
end
