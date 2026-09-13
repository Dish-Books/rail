defmodule Rail.Domain.OverviewQueueTest do
  use ExUnit.Case, async: true

  alias Rail.Domain.AgentRow
  alias Rail.Domain.OverviewQueue
  alias Rail.Domain.OverviewQueueState
  alias Rail.Domain.RunAttentionItem
  alias Rail.Domain.WaitingRow
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
          task: struct(%Task{id: "tsk_1", stage: :product}, task_attrs)
        },
        run_attrs
      )
    end

    %{run: run}
  end

  test "a blocked run is the only thing waiting on a human", %{run: run} do
    assert OverviewQueue.needs_attention?(run.(%{status: :blocked_on_input}))
    refute OverviewQueue.needs_attention?(run.(%{stage_outcome: :done}))
    refute OverviewQueue.needs_attention?(run.(%{error: "boom"}))
    refute OverviewQueue.needs_attention?(run.(%{status: :running}))
  end

  test "a blocked run stays waiting while its answers are gathered", %{run: run} do
    answered = run.(%{status: :blocked_on_input, questions: [%Question{status: :answered}]})

    assert OverviewQueue.needs_attention?(answered)
  end

  test "a merged task needs nothing from anybody", %{run: run} do
    merged_stage = run.(%{status: :blocked_on_input, task: %{stage: :merged}})
    merged_at = run.(%{status: :blocked_on_input, task: %{merged_at: ~U[2026-01-01 10:00:00Z]}})

    refute OverviewQueue.needs_attention?(merged_stage)
    refute OverviewQueue.needs_attention?(merged_at)
  end

  test "waiting rows keep the order they arrived in", %{run: run} do
    %{id: first_id} = first = run.(%{status: :blocked_on_input})
    %{id: second_id} = second = run.(%{status: :blocked_on_input})

    items = Enum.map([first, second], &RunAttentionItem.new/1)

    assert %OverviewQueueState{waiting: [%WaitingRow{run: %{id: ^first_id}}, %WaitingRow{run: %{id: ^second_id}}]} =
             OverviewQueue.build_overview_queue(items, [], fn _key -> nil end)
  end

  test "a row waits since the queue says it did, not since the run stopped", %{run: run} do
    stamped = ~U[2026-02-02 08:00:00Z]
    item = RunAttentionItem.new(run.(%{status: :blocked_on_input}))

    assert %OverviewQueueState{waiting: [%WaitingRow{waiting_since: ^stamped}]} =
             OverviewQueue.build_overview_queue([item], [], fn _key -> stamped end)
  end

  test "a row falls back to when the run stopped if the queue has no stamp", %{run: run} do
    item = RunAttentionItem.new(run.(%{status: :blocked_on_input}))
    stopped = ~U[2026-01-01 10:00:00Z]

    assert %OverviewQueueState{waiting: [%WaitingRow{waiting_since: ^stopped}]} =
             OverviewQueue.build_overview_queue([item], [], fn _key -> nil end)
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
