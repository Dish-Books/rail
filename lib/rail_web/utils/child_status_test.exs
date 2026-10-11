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
    roles = Map.new([:engineer, :review_lead], &{&1, %Role{id: "rol_#{&1}", name: "#{&1} role", stage: &1}})

    child = fn position, attrs ->
      struct(
        %Task{
          id: "tsk_#{position}",
          split_position: position,
          builds_on: [],
          stage: :engineer,
          runs: [],
          scratch_path: "/nonexistent/child_status",
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
             cells: [%{mark: :done}, %{mark: :done}, %{mark: :done}],
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
        runs: [run.(:engineer, stage_outcome: :done), run.(:review_lead, status: :finished, stage_outcome: :done)]
      )

    assert %{
             label: "Review",
             cells: [%{mark: :done}, %{mark: :current, chip: %{label: "Findings"}}, %{mark: :pending}],
             line: "Findings to rule",
             needs_attention: true,
             badge: :dot,
             action: %{label: "Review", tab: "rol_review_lead"}
           } = child_status(at_review, [at_review])
  end

  test "a child whose Review round waits on a person takes the Findings icon, until it is ready to merge", %{
    child: child,
    run: run
  } do
    scratch = Path.join(System.tmp_dir!(), "child_status_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)

    at_review =
      child.(1,
        stage: :review,
        scratch_path: scratch,
        runs: [run.(:review_lead, status: :finished, stage_outcome: :done)]
      )

    diff_ready = child.(2, runs: [run.(:engineer, status: :finished, stage_outcome: :done)])

    assert %{
             icon: "pi-list-checks",
             text_class: "text-amber" <> _amber,
             cells: [%{mark: :done}, %{chip: %{label: "Findings", icon: "pi-list-checks"}}, _finalize]
           } = child_status(at_review, [at_review])

    assert %{icon: "pi-chat-text", cells: [%{chip: %{label: "Diff", icon: "pi-chat-text"}}, _review, _finalize]} =
             child_status(diff_ready, [diff_ready])

    File.mkdir_p!(Path.join(scratch, "reviews"))

    File.write!(
      Path.join(scratch, "reviews/SPL-1.json"),
      ~s({"passes": [{"round": 1, "saved_at": "2026-10-01T10:00:00Z", "head": "abc", "finished_at": "2026-10-01T11:00:00Z"}]})
    )

    assert %{
             label: "Ready to merge",
             icon: "pi-chat-text",
             cells: [_engineer, %{chip: %{label: "Findings", icon: "pi-chat-text"}}, _finalize]
           } = child_status(at_review, [at_review])
  end

  test "a blocked or failed child carries the badge and its action, and a running one does not", %{
    child: child,
    run: run
  } do
    asked = [%Question{status: :pending}, %Question{status: :pending}]
    blocked = child.(1, runs: [run.(:engineer, status: :blocked_on_input, questions: asked)])
    failed = child.(2, stage: :review, runs: [run.(:review_lead, status: :failed, error: "Chrome could not reach it")])
    running = child.(3, runs: [run.(:engineer, status: :running)])

    assert %{badge: 2, line: "engineer role asked 2 questions", action: %{label: "Answer", tab: "rol_engineer"}} =
             child_status(blocked, [blocked])

    assert %{
             badge: :dot,
             label: "Review failed",
             line: "Review failed: Chrome could not reach it",
             line_class: "text-red-600 dark:text-red-500",
             action: %{label: "Fix", tab: "rol_review_lead"},
             cells: [%{mark: :done}, %{chip: %{label: "Failed"}}, _finalize]
           } = child_status(failed, [failed])

    assert %{
             badge: nil,
             needs_attention: false,
             action: nil,
             line: "Implement running · " <> _age,
             cells: [%{chip: %{label: "Running"}} | _rest]
           } =
             child_status(running, [running])
  end

  test "every other state reads its own line", %{child: child, run: run} do
    queued = child.(1, [])

    one_question =
      child.(2, runs: [run.(:engineer, status: :blocked_on_input, questions: [%Question{status: :answered}])])

    assert %{state: :queued, line: "Queued for Implement", badge: nil} = child_status(queued, [queued])
    assert %{line: "engineer role asked a question", badge: :dot} = child_status(one_question, [one_question])

    for {status, stage, role, line} <- [
          {%{status: :finished, stage_outcome: :done}, :engineer, :engineer, "Diff ready for review"},
          {%{status: :finished, stage_outcome: :done}, :review, :review_lead, "Findings to rule"},
          {%{status: :waiting_for_resources}, :engineer, :engineer, "Implement waiting for resources"},
          {%{status: :finished}, :engineer, :engineer, "Implement stopped"}
        ] do
      task = child.(3, stage: stage, runs: [run.(role, Map.to_list(status))])
      assert %{line: ^line} = child_status(task, [task])
    end
  end

  test "every state has one cell per child stage, in order, so a row always fills the board's stage columns", %{
    child: child,
    run: run,
    now: now
  } do
    merged = child.(1, issue: %Issue{identifier: "SPL-1", completed_at: now})
    canceled = child.(2, issue: %Issue{identifier: "SPL-2", state: :canceled})
    blocked = child.(3, builds_on: [2])
    waiting = child.(4, builds_on: [5])
    at_engineer = child.(5, runs: [run.(:engineer, status: :running)])
    at_review = child.(6, stage: :review, runs: [run.(:review_lead, status: :finished, stage_outcome: :done)])
    at_finalize = child.(7, stage: :finalize, runs: [run.(:review_lead, status: :finished, stage_outcome: :done)])
    siblings = [merged, canceled, blocked, waiting, at_engineer, at_review, at_finalize]

    assert child_stages() == [:engineer, :review, :finalize]

    assert [:merged, :canceled, :blocked_by_canceled, :waiting_on, :running, :done, :not_ready] =
             for(sibling <- siblings, do: child_status(sibling, siblings).state)

    for sibling <- siblings do
      assert [%{stage: :engineer}, %{stage: :review}, %{stage: :finalize}] = child_status(sibling, siblings).cells
    end
  end

  test "a child merged through Finalize reads merged before Linear completes its issue", %{child: child, now: now} do
    merged = child.(1, stage: :merged, merged_at: now, pr_number: 151)
    after_it = child.(2, builds_on: [1])

    assert %{state: :merged, line: "Merged · PR #151"} = child_status(merged, [merged, after_it])
    assert %{state: :queued, waiting_on: []} = child_status(after_it, [merged, after_it])
  end

  test "a child at Finalize sits in the Finalize column with its label, flagged only until marked ready", %{
    child: child,
    run: run,
    now: now
  } do
    lead = [run.(:review_lead, status: :running)]
    unmarked = child.(1, stage: :finalize, runs: lead)

    assert %{
             state: :not_ready,
             label: "Ready to finalize",
             cells: [%{mark: :done}, %{mark: :done}, %{mark: :current, chip: %{label: "Ready to finalize"}}],
             needs_attention: true,
             badge: :dot,
             action: %{label: "Finalize", tab: "finalize"}
           } = child_status(unmarked, [unmarked])

    ready = %{unmarked | marked_ready_at: now}

    assert %{state: :ready, line: "Ready for tech lead", needs_attention: false, badge: nil, action: nil} =
             child_status(ready, [ready])

    refused = %{ready | merge_error: "Required check failed"}
    assert %{state: :refused, line: "Merge refused: Required check failed"} = child_status(refused, [refused])
  end

  test "a failed child at the engineer stage reads Implement failed", %{child: child, run: run} do
    failed = child.(1, runs: [run.(:engineer, status: :finished, error: "It broke.")])
    assert %{label: "Implement failed", line: "Implement failed: It broke."} = child_status(failed, [failed])
  end
end
