defmodule Rail.Domain.OverviewQueueTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.AgentRow
  alias Rail.Domain.CompactStripBlock
  alias Rail.Domain.OverviewQueue
  alias Rail.Domain.OverviewQueueState
  alias Rail.Domain.QuestionAttentionItem
  alias Rail.Domain.SingleCardBlock
  alias Rail.Domain.TaskAttentionItem
  alias Rail.Domain.WaitingRow
  alias Rail.Runs.Schemas.Run

  test "waiting_kind_for/2 classifies all paths according to precedence" do
    done = %Run{status: :finished, stage_outcome: :done}
    failed = %Run{status: :finished, error: "boom"}

    t_approval = %{stage: :architect, run: done}
    t_failed = %{stage: :engineer, run: failed}
    t_merge = %{stage: :ready_to_merge, run: done}
    t_conflicted = %{stage: :engineer, shows_as_conflicted: true, run: done}
    t_other = %{stage: :review, run: %Run{status: :finished}}

    q = %{id: "q-1", prompt: "Pick one"}

    # 1. Question not nil -> :question
    assert OverviewQueue.waiting_kind_for(t_approval, q) == :question
    assert OverviewQueue.waiting_kind_for(t_failed, q) == :question

    # 2. Task is nil -> :question
    assert OverviewQueue.waiting_kind_for(nil, nil) == :question
    assert OverviewQueue.waiting_kind_for(nil, q) == :question

    # 3. awaiting_approval and stage != ready_to_merge and not conflicted -> :approval
    assert OverviewQueue.waiting_kind_for(t_approval, nil) == :approval

    # 4. failed -> :failed
    assert OverviewQueue.waiting_kind_for(t_failed, nil) == :failed

    # 5. ready_to_merge -> :ready_to_merge
    assert OverviewQueue.waiting_kind_for(t_merge, nil) == :ready_to_merge

    # 6. conflicted -> :conflicts
    assert OverviewQueue.waiting_kind_for(t_conflicted, nil) == :conflicts

    # 7. other -> :approval
    assert OverviewQueue.waiting_kind_for(t_other, nil) == :approval

    # Failed stage with stale question_id classifies as :failed when pending question is nil
    t_stale = %{stage: :engineer, question_id: "q-stale", run: failed}
    assert OverviewQueue.waiting_kind_for(t_stale, nil) == :failed
  end

  test "compact_kind?/1 returns true only for compact kinds" do
    assert OverviewQueue.compact_kind?(:failed)
    assert OverviewQueue.compact_kind?(:ready_to_merge)
    assert OverviewQueue.compact_kind?(:conflicts)

    assert OverviewQueue.compact_kind?("failed")
    assert OverviewQueue.compact_kind?("ready_to_merge")
    assert OverviewQueue.compact_kind?("conflicts")

    refute OverviewQueue.compact_kind?(:question)
    refute OverviewQueue.compact_kind?(:approval)
    refute OverviewQueue.compact_kind?(:other)
  end

  test "merged?/1 detects all merged representations" do
    assert OverviewQueue.merged?(%{is_merged: true})
    assert OverviewQueue.merged?(%{stage: :merged})
    assert OverviewQueue.merged?(%{stage: "merged"})
    assert OverviewQueue.merged?(%{merged_at: ~U[2026-01-01 12:00:00Z]})

    refute OverviewQueue.merged?(%{is_merged: false, stage: :engineer})
    refute OverviewQueue.merged?(%{})
  end

  test "needs_attention?/1 logic" do
    # Explicit boolean field takes priority
    assert OverviewQueue.needs_attention?(%{needs_attention: true})
    refute OverviewQueue.needs_attention?(%{needs_attention: false})

    # Merged tasks never need attention
    refute OverviewQueue.needs_attention?(%{is_merged: true})

    # Busy tasks never need attention
    refute OverviewQueue.needs_attention?(%{is_busy: true})

    # ready_to_merge
    assert OverviewQueue.needs_attention?(%{stage: :ready_to_merge})
    refute OverviewQueue.needs_attention?(%{stage: :ready_to_merge, is_rebasing: true})

    # A stage that is done, failed, blocked or stopped is waiting on a human.
    assert OverviewQueue.needs_attention?(%{stage: :architect, run: %Run{status: :finished, stage_outcome: :done}})
    assert OverviewQueue.needs_attention?(%{stage: :engineer, run: %Run{status: :finished, error: "boom"}})
    assert OverviewQueue.needs_attention?(%{stage: :engineer, run: %Run{status: :blocked_on_input}})
    assert OverviewQueue.needs_attention?(%{stage: :engineer, run: %Run{status: :finished}})

    # Conflicts
    assert OverviewQueue.needs_attention?(%{stage: :engineer, conflicted: true, run: %Run{status: :finished}})

    refute OverviewQueue.needs_attention?(%{
             stage: :engineer,
             conflicted: true,
             is_rebasing: true,
             run: %Run{status: :running}
           })

    # A stage still working, and one that has not started, are not waiting.
    refute OverviewQueue.needs_attention?(%{stage: :engineer, run: %Run{status: :running}})
    refute OverviewQueue.needs_attention?(%{stage: :engineer})
  end

  test "conflicted?/1 detects conflicts across representation forms" do
    assert OverviewQueue.conflicted?(%{shows_as_conflicted: true})
    assert OverviewQueue.conflicted?(%{conflicted: true})
    assert OverviewQueue.conflicted?(%{has_merge_conflicts: true})
    assert OverviewQueue.conflicted?(%{mergeability: :conflicts})
    assert OverviewQueue.conflicted?(%{mergeability: "conflicts"})

    refute OverviewQueue.conflicted?(%{mergeability: :conflicts, is_rebasing: true})
    refute OverviewQueue.conflicted?(%{has_merge_conflicts: true, run: %Run{status: :running}})
    refute OverviewQueue.conflicted?(%{mergeability: :clean})
  end

  test "build_overview_queue classifies waiting rows and groups adjacent compact rows (AC 3, AC 4)" do
    t_appr = %{
      id: "task-appr",
      title: "Needs Approval",
      stage: :architect,
      run: %Run{status: :finished, stage_outcome: :done},
      created_at: ~U[2026-01-01 10:00:00Z],
      updated_at: ~U[2026-01-01 10:00:00Z]
    }

    t_fail = %{
      id: "task-fail",
      title: "Build Failed",
      stage: :engineer,
      run: %Run{status: :finished, error: "boom"},
      created_at: ~U[2026-01-01 10:01:00Z],
      updated_at: ~U[2026-01-01 10:01:00Z]
    }

    t_merge = %{
      id: "task-merge",
      title: "Ready to Merge",
      stage: :ready_to_merge,
      run: %Run{status: :finished, stage_outcome: :done},
      created_at: ~U[2026-01-01 10:02:00Z],
      updated_at: ~U[2026-01-01 10:02:00Z]
    }

    q_item = %{
      id: "q-1",
      prompt: "Which direction?",
      created_at: ~U[2026-01-01 10:03:00Z]
    }

    waiting = [
      TaskAttentionItem.new(t_appr),
      TaskAttentionItem.new(t_fail),
      TaskAttentionItem.new(t_merge),
      QuestionAttentionItem.new(q_item)
    ]

    all_tasks = [t_appr, t_fail, t_merge]

    state =
      OverviewQueue.build_overview_queue(
        waiting: waiting,
        tasks: all_tasks,
        question_for: fn _task -> nil end,
        waiting_since: fn _key -> ~U[2026-01-01 10:00:00Z] end
      )

    # 4 waiting items:
    # 1. Approval (card) -> SingleCardBlock
    # 2. Failed (compact) \
    # 3. Merge (compact)   -> CompactStripBlock with 2 rows
    # 4. Question (card) -> SingleCardBlock
    assert length(state.waiting) == 3

    assert %SingleCardBlock{
             row: %{kind: :approval, task: %{id: "task-appr"}, waiting_since: ~U[2026-01-01 10:00:00Z]}
           } = Enum.at(state.waiting, 0)

    assert %CompactStripBlock{rows: strip_rows} = Enum.at(state.waiting, 1)
    assert length(strip_rows) == 2
    assert Enum.at(strip_rows, 0).kind == :failed
    assert Enum.at(strip_rows, 0).task.id == "task-fail"
    assert Enum.at(strip_rows, 1).kind == :ready_to_merge
    assert Enum.at(strip_rows, 1).task.id == "task-merge"

    assert %SingleCardBlock{row: %{kind: :question, question: %{id: "q-1"}}} = Enum.at(state.waiting, 2)
  end

  test "preserves queue order across interleaved card and compact items (strip / card / strip)" do
    failed = %Run{status: :finished, error: "boom"}
    done = %Run{status: :finished, stage_outcome: :done}

    t_fail1 = %{id: "f1", stage: :engineer, run: failed}
    t_appr = %{id: "a1", stage: :architect, run: done}
    t_fail2 = %{id: "f2", stage: :engineer, run: failed}

    waiting = [
      TaskAttentionItem.new(t_fail1),
      TaskAttentionItem.new(t_appr),
      TaskAttentionItem.new(t_fail2)
    ]

    # Calling with map arguments
    state =
      OverviewQueue.build_overview_queue(%{
        waiting: waiting,
        tasks: [t_fail1, t_appr, t_fail2],
        question_for: fn _task -> nil end,
        waiting_since: fn _key -> ~U[2026-01-01 10:00:00Z] end
      })

    assert length(state.waiting) == 3
    assert %CompactStripBlock{} = Enum.at(state.waiting, 0)
    assert %SingleCardBlock{} = Enum.at(state.waiting, 1)
    assert %CompactStripBlock{} = Enum.at(state.waiting, 2)
  end

  test "withAgent filters out merged and waiting tasks, and sorts by updatedAt descending (AC 2, AC 4, AC 7)" do
    t_running = %{
      id: "task-running",
      title: "Running Task",
      stage: :engineer,
      run: %Run{status: :running},
      updated_at: ~U[2026-01-01 11:00:00Z]
    }

    t_queued = %{
      id: "task-queued",
      title: "Queued Task",
      stage: :design,
      updated_at: ~U[2026-01-01 12:00:00Z]
    }

    t_waiting = %{
      id: "task-waiting",
      title: "Waiting Task",
      stage: :architect,
      run: %Run{status: :finished, stage_outcome: :done},
      updated_at: ~U[2026-01-01 13:00:00Z]
    }

    t_merged = %{
      id: "task-merged",
      title: "Merged Task",
      stage: :merged,
      updated_at: ~U[2026-01-01 14:00:00Z]
    }

    all_tasks = [t_running, t_queued, t_waiting, t_merged]
    waiting = [TaskAttentionItem.new(t_waiting)]

    # Calling with 4-arity function
    state =
      OverviewQueue.build_overview_queue(
        waiting,
        all_tasks,
        fn _task -> nil end,
        fn _key -> ~U[2026-01-01 10:00:00Z] end
      )

    assert length(state.waiting) == 1
    assert %SingleCardBlock{row: %{task: %{id: "task-waiting"}}} = hd(state.waiting)

    # withAgent has queued and running, NOT waiting, NOT merged
    assert length(state.with_agent) == 2
    # sorted by updatedAt descending: queued (12:00) then running (11:00)
    assert Enum.at(state.with_agent, 0).task.id == "task-queued"
    assert Enum.at(state.with_agent, 1).task.id == "task-running"
  end

  test "withAgent sort handles inserted_at, created_at, and nil timestamps" do
    t1 = %{id: "t1", stage: :engineer, inserted_at: ~U[2026-01-01 10:00:00Z]}
    t2 = %{id: "t2", stage: :engineer, created_at: ~U[2026-01-01 12:00:00Z]}
    t3 = %{id: "t3", stage: :engineer}
    t4 = %{id: "t4", stage: :engineer}

    # Pass in order [t3, t4, t1, t2] to trigger comparison with {nil, %DateTime{}} and {nil, nil}
    state = OverviewQueue.build_overview_queue(waiting: [], tasks: [t3, t4, t1, t2])

    ids = Enum.map(state.with_agent, & &1.task.id)
    assert ids == ["t2", "t1", "t3", "t4"]
  end

  test "alias modules and question extraction variations" do
    t1 = %{id: "t1", stage: :architect}
    q1 = %{id: "q1", prompt: "Hello"}

    # Question from question_for
    q_lookup = fn task -> if task.id == "t1", do: q1 end

    state = OverviewQueue.build_overview_queue(waiting: [%{task: t1}], tasks: [t1], question_for: q_lookup)
    assert length(state.waiting) == 1
    assert %SingleCardBlock{row: %{kind: :question, question: ^q1}} = hd(state.waiting)

    # Map with question key
    state2 = OverviewQueue.build_overview_queue(waiting: [%{question: q1}], tasks: [])
    assert length(state2.waiting) == 1
    assert %SingleCardBlock{row: %{kind: :question, task: nil}} = hd(state2.waiting)

    # Unknown item type
    state3 = OverviewQueue.build_overview_queue(waiting: ["raw_string"], tasks: [])
    assert length(state3.waiting) == 1

    # Struct aliases
    s_block = %SingleCardBlock{row: %WaitingRow{item: "x", kind: :approval, waiting_since: nil}}
    assert s_block.row.kind == :approval

    c_block = %CompactStripBlock{rows: []}
    assert c_block.rows == []

    a_row = %AgentRow{task: t1}
    assert a_row.task == t1

    queue_state = %OverviewQueueState{waiting: [s_block], with_agent: [a_row]}
    assert queue_state.waiting == [s_block]
  end

  test "handles map options, struct tasks, string keys, and invalid stages" do
    map_opts = %{
      "waiting" => [],
      "tasks" => [
        %URI{path: "/task/1"},
        %{"id" => "str_task", "stage" => "engineer", "stage_state" => "running"},
        %{id: "bad_stage", stage: "non_existent_atom_xyz"}
      ]
    }

    state = OverviewQueue.build_overview_queue(map_opts)
    assert length(state.with_agent) == 3

    assert OverviewQueue.waiting_kind_for(nil, nil) == :question
    assert OverviewQueue.waiting_kind_for(123, nil) == :approval

    refute OverviewQueue.merged?(nil)
    refute OverviewQueue.needs_attention?(nil)
    refute OverviewQueue.conflicted?(nil)

    # Sorting tasks where first has timestamp and second is nil
    t_has_time = %{id: "has_time", stage: :engineer, created_at: ~U[2026-01-01 12:00:00Z]}
    t_no_time = %{id: "no_time", stage: :engineer}
    state_sort = OverviewQueue.build_overview_queue(waiting: [], tasks: [t_has_time, t_no_time])
    assert Enum.map(state_sort.with_agent, & &1.task.id) == ["has_time", "no_time"]
  end
end
