defmodule RailWeb.Utils.ChildStatusTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.ChildStatus

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role

  setup do
    now = DateTime.utc_now()
    roles = Map.new([:engineer, :review, :qa], &{&1, %Role{id: "rol_#{&1}", name: "#{&1} role", stage: &1}})

    child = fn position, attrs ->
      struct(
        %Task{
          id: "tsk_#{position}",
          split_position: position,
          builds_on: [],
          stage: :engineer,
          runs: [],
          issue: %Issue{identifier: "SPL-#{position}", title: "Child #{position}"}
        },
        attrs
      )
    end

    run = fn stage, attrs ->
      struct(%Run{role: roles[stage], role_id: roles[stage].id, questions: [], started_at: now}, attrs)
    end

    %{child: child, run: run, now: now}
  end

  test "a merged child reads Merged with its pull request", %{child: child, now: now} do
    merged = child.(1, issue: %Issue{identifier: "SPL-1", completed_at: now}, pr_number: 212)

    assert %{
             state: :merged,
             label: "Merged",
             line: "Merged · PR #212",
             needs_attention: false,
             cells: [%{mark: :done}, %{mark: :done}, %{mark: :done}, %{mark: :done}],
             merged: %{chip: %{label: "Merged"}}
           } = child_status(merged, [merged])
  end

  test "a child canceled in Linear reads Canceled, with no badge, no action and nobody waited on", %{
    child: child,
    run: run
  } do
    canceled =
      child.(1,
        issue: %Issue{identifier: "SPL-1", state: :canceled},
        runs: [run.(:engineer, status: :failed, error: "It broke.")]
      )

    assert %{
             state: :canceled,
             label: "Canceled",
             needs_attention: false,
             badge: nil,
             action: nil,
             line: "Canceled in Linear",
             merged: %{chip: %{label: "Canceled"}}
           } = child_status(canceled, [canceled])
  end

  test "a child with no run building on a canceled sibling is blocked by it, and flagged to its owner", %{
    child: child
  } do
    first = child.(1, [])
    second = child.(2, issue: %Issue{identifier: "SPL-2", state: :canceled})
    third = child.(3, builds_on: [1, 2])

    assert %{
             state: :blocked_by_canceled,
             label: "Blocked by SPL-2",
             icon: "pi-warning-circle",
             needs_attention: true,
             badge: :dot,
             action: nil,
             waiting_on: ["SPL-1"],
             line: "SPL-2 was canceled, so this will not start; cancel it in Linear to finish the split",
             cells: [%{stage: :engineer, mark: :current, chip: %{label: "Blocked"}} | _rest]
           } = child_status(third, [first, second, third])

    assert %{state: :waiting_on, waiting_on: ["SPL-1", "SPL-2"]} = child_status(third, [first, child.(2, []), third])
  end

  test "a child building on a sibling whose task is gone, with its issue deleted in Linear, is blocked by it", %{
    child: child
  } do
    first = child.(1, [])
    third = child.(3, builds_on: [1, 2])

    assert %{
             state: :blocked_by_canceled,
             label: "Blocked by child 2",
             needs_attention: true,
             badge: :dot,
             waiting_on: ["SPL-1"],
             after: ["SPL-1", "child 2"],
             line: "child 2 was removed in Linear, so this will not start; cancel it in Linear to finish the split"
           } = child_status(third, [first, third])
  end

  test "a child with no run and an unmerged earlier sibling waits on it in slate, in the Engineer column", %{
    child: child,
    now: now
  } do
    first = child.(1, [])
    second = child.(2, issue: %Issue{identifier: "SPL-2", completed_at: now})
    third = child.(3, builds_on: [1, 2])

    assert %{
             state: :waiting_on,
             label: "Waiting on SPL-1",
             icon: "pi-clock",
             text_class: "text-slate-500 dark:text-slate-400",
             line: "Starts when SPL-1 merges",
             after: ["SPL-1", "SPL-2"],
             waiting_on: ["SPL-1"],
             badge: nil,
             cells: [%{stage: :engineer, mark: :current, chip: %{label: "Waiting"}}, %{mark: :pending} | _rest]
           } = child_status(third, [first, second, third])

    assert %{line: "Starts when SPL-1 and SPL-2 merge"} =
             child_status(third, [first, %{second | issue: %Issue{identifier: "SPL-2"}}, third])
  end

  test "a child at Review shows Engineer done and Review current, and its action opens Review's tab", %{
    child: child,
    run: run
  } do
    at_review =
      child.(1,
        stage: :review,
        runs: [run.(:engineer, stage_outcome: :done), run.(:review, status: :finished, stage_outcome: :done)]
      )

    assert %{
             label: "Review the findings",
             cells: [%{mark: :done}, %{mark: :current, chip: %{label: "Findings"}}, %{mark: :pending}, %{mark: :pending}],
             line: "Findings to rule",
             needs_attention: true,
             badge: :dot,
             action: %{label: "Review the findings", tab: "rol_review"}
           } = child_status(at_review, [at_review])
  end

  test "a blocked or failed child carries the badge and its action, and a running one does not", %{
    child: child,
    run: run
  } do
    asked = [%Question{status: :pending}, %Question{status: :pending}]
    blocked = child.(1, runs: [run.(:engineer, status: :blocked_on_input, questions: asked)])
    failed = child.(2, stage: :qa, runs: [run.(:qa, status: :failed, error: "Chrome could not reach it")])
    running = child.(3, runs: [run.(:engineer, status: :running)])

    assert %{badge: 2, line: "engineer role asked 2 questions", action: %{label: "Answer", tab: "rol_engineer"}} =
             child_status(blocked, [blocked])

    assert %{
             badge: :dot,
             label: "QA failed",
             line: "QA failed: Chrome could not reach it",
             line_class: "text-red-600 dark:text-red-500",
             action: %{label: "Fix", tab: "rol_qa"},
             cells: [%{mark: :done}, %{mark: :done}, %{chip: %{label: "Failed"}}, %{mark: :pending}]
           } = child_status(failed, [failed])

    assert %{
             badge: nil,
             needs_attention: false,
             action: nil,
             line: "Engineer running · " <> _age,
             cells: [%{chip: %{label: "Running"}} | _rest]
           } =
             child_status(running, [running])
  end

  test "every other state reads its own line", %{child: child, run: run} do
    queued = child.(1, [])

    one_question =
      child.(2, runs: [run.(:engineer, status: :blocked_on_input, questions: [%Question{status: :answered}])])

    assert %{state: :queued, line: "Queued for Engineer", badge: nil} = child_status(queued, [queued])
    assert %{line: "engineer role asked a question", badge: :dot} = child_status(one_question, [one_question])

    for {status, stage, line} <- [
          {%{status: :finished, stage_outcome: :done}, :engineer, "Diff ready for review"},
          {%{status: :finished, stage_outcome: :done}, :qa, "QA report ready"},
          {%{status: :waiting_for_resources}, :engineer, "Engineer waiting for resources"},
          {%{status: :finished}, :engineer, "Engineer stopped"}
        ] do
      task = child.(3, stage: stage, runs: [run.(stage, Map.to_list(status))])
      assert %{line: ^line} = child_status(task, [task])
    end

    demo =
      child.(4,
        stage: :demo,
        runs: [
          :engineer
          |> run.(status: :finished, stage_outcome: :done)
          |> Map.put(:role, %Role{id: "rol_demo", name: "Demo", stage: :demo})
        ]
      )

    assert %{line: "Demo recorded", cells: [_e, _r, _q, %{chip: %{label: "Demo"}}]} = child_status(demo, [demo])
  end
end
