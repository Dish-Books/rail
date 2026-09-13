defmodule Rail.Domain.OverviewQueueTest do
  use ExUnit.Case, async: true

  alias Rail.Domain.AgentRow
  alias Rail.Domain.CompactStripBlock
  alias Rail.Domain.OverviewQueue
  alias Rail.Domain.OverviewQueueState
  alias Rail.Domain.RunAttentionItem
  alias Rail.Domain.SingleCardBlock
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Runs.Schemas.Run

  setup do
    run = fn attrs ->
      {task_attrs, run_attrs} = Map.pop(attrs, :task, %{})

      struct(
        %Run{
          id: "run_#{System.unique_integer([:positive])}",
          status: :finished,
          questions: [],
          completed_at: ~U[2026-01-01 10:00:00Z],
          task: struct(%Task{id: "tsk_1", stage: :engineer}, task_attrs)
        },
        run_attrs
      )
    end

    %{run: run}
  end

  test "a blocked run is waiting on an answer", %{run: run} do
    blocked = run.(%{status: :blocked_on_input, questions: [%Question{status: :pending}]})

    assert OverviewQueue.waiting_kind_for(blocked) == :question
  end

  test "a blocked run stays a question card while its answers are gathered", %{run: run} do
    answered = run.(%{status: :blocked_on_input, questions: [%Question{status: :answered}]})

    assert OverviewQueue.waiting_kind_for(answered) == :question
  end

  test "a run that said it was done is waiting on approval", %{run: run} do
    assert OverviewQueue.waiting_kind_for(run.(%{stage_outcome: :done})) == :approval
  end

  test "a run that recorded an error is waiting as a failure", %{run: run} do
    assert OverviewQueue.waiting_kind_for(run.(%{error: "boom"})) == :failed
  end

  test "a task that cannot be merged outranks what its run said", %{run: run} do
    conflicted = run.(%{stage_outcome: :done, task: %{mergeability: :conflicting}})

    assert OverviewQueue.waiting_kind_for(conflicted) == :conflicts
  end

  test "a task at ready to merge is waiting on the merge", %{run: run} do
    assert OverviewQueue.waiting_kind_for(run.(%{task: %{stage: :ready_to_merge}})) == :ready_to_merge
  end

  test "only failures, merges and conflicts are compact" do
    assert OverviewQueue.compact_kind?(:failed)
    assert OverviewQueue.compact_kind?(:ready_to_merge)
    assert OverviewQueue.compact_kind?(:conflicts)
    refute OverviewQueue.compact_kind?(:question)
    refute OverviewQueue.compact_kind?(:approval)
  end

  test "a run needs attention once it has stopped saying anything", %{run: run} do
    assert OverviewQueue.needs_attention?(run.(%{stage_outcome: :done}))
    assert OverviewQueue.needs_attention?(run.(%{error: "boom"}))
    assert OverviewQueue.needs_attention?(run.(%{status: :blocked_on_input}))
    assert OverviewQueue.needs_attention?(run.(%{status: :finished}))
    refute OverviewQueue.needs_attention?(run.(%{status: :running}))
  end

  test "a merged task needs nothing from anybody", %{run: run} do
    merged_stage = run.(%{stage_outcome: :done, task: %{stage: :merged}})
    merged_at = run.(%{stage_outcome: :done, task: %{merged_at: ~U[2026-01-01 10:00:00Z]}})

    refute OverviewQueue.needs_attention?(merged_stage)
    refute OverviewQueue.needs_attention?(merged_at)
  end

  test "a conflicted task needs attention even while its run sits idle", %{run: run} do
    assert OverviewQueue.needs_attention?(run.(%{task: %{mergeability: :conflicting}}))
  end

  test "waiting rows keep arrival order and adjacent compact rows group into one strip", %{run: run} do
    approval = run.(%{stage_outcome: :done})
    failed_one = run.(%{error: "one"})
    failed_two = run.(%{error: "two"})
    question = run.(%{status: :blocked_on_input, questions: [%Question{status: :pending}]})

    items = Enum.map([approval, failed_one, failed_two, question], &RunAttentionItem.new/1)

    assert %OverviewQueueState{waiting: waiting} =
             OverviewQueue.build_overview_queue(items, [], fn _key -> nil end)

    assert [
             %SingleCardBlock{row: %{kind: :approval}},
             %CompactStripBlock{rows: [%{kind: :failed}, %{kind: :failed}]},
             %SingleCardBlock{row: %{kind: :question}}
           ] = waiting
  end

  test "a row waits since the queue says it did, not since the run stopped", %{run: run} do
    stamped = ~U[2026-02-02 08:00:00Z]
    item = RunAttentionItem.new(run.(%{stage_outcome: :done}))

    assert %OverviewQueueState{waiting: [%SingleCardBlock{row: %{waiting_since: ^stamped}}]} =
             OverviewQueue.build_overview_queue([item], [], fn _key -> stamped end)
  end

  test "with-agent rows are the running runs, most recently started first", %{run: run} do
    %{id: older_id} = older = run.(%{status: :running, started_at: ~U[2026-01-01 09:00:00Z]})
    %{id: newer_id} = newer = run.(%{status: :running, started_at: ~U[2026-01-01 11:00:00Z]})
    idle = run.(%{stage_outcome: :done})

    assert %OverviewQueueState{
             with_agent: [%AgentRow{run: %{id: ^newer_id}}, %AgentRow{run: %{id: ^older_id}}]
           } = OverviewQueue.build_overview_queue([], [older, newer, idle], fn _key -> nil end)
  end
end
