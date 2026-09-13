defmodule Rail.Domain.AttentionQueueTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.AttentionItem
  alias Rail.Domain.AttentionQueue
  alias Rail.Domain.RunAttentionItem
  alias Rail.Runs.Schemas.Run

  test "new/1 initializes default and custom state" do
    default_q = AttentionQueue.new()
    assert default_q.arrivals == %{}
    assert default_q.tick == 0
    refute default_q.has_seeded
    assert is_function(default_q.clock, 0)
    assert default_q.items == []

    fixed_time = ~U[2026-01-01 12:00:00Z]
    custom_clock = fn -> fixed_time end

    custom_q =
      AttentionQueue.new(
        clock: custom_clock,
        tick: 5,
        has_seeded: true,
        arrivals: %{"run:1" => %{tick: 5, natural_created_at: fixed_time, first_seen_at: fixed_time}}
      )

    assert custom_q.tick == 5
    assert custom_q.has_seeded
    assert custom_q.clock.() == fixed_time
    assert Map.has_key?(custom_q.arrivals, "run:1")
  end

  test "wraps a run, keyed by it and waiting since it stopped" do
    completed = ~U[2026-01-01 10:00:00Z]
    item = RunAttentionItem.new(%Run{id: "run_1", completed_at: completed})

    assert item.key == "run:run_1"
    assert item.waiting_since == completed
    assert AttentionItem.key(item) == "run:run_1"
    assert AttentionItem.waiting_since(item) == completed
  end

  test "falls back to when the run was last touched" do
    updated = ~U[2026-01-01 09:00:00Z]
    item = RunAttentionItem.new(%Run{id: "run_2", completed_at: nil, updated_at: updated})

    assert item.waiting_since == updated
  end

  test "cold start sorts items by naturalCreatedAt oldest-first" do
    t1 = RunAttentionItem.new(%Run{id: "t1", completed_at: ~U[2026-01-01 10:00:00Z]})
    # oldest
    t2 = RunAttentionItem.new(%Run{id: "t2", completed_at: ~U[2026-01-01 09:00:00Z]})
    t3 = RunAttentionItem.new(%Run{id: "t3", completed_at: ~U[2026-01-01 11:00:00Z]})
    q1 = RunAttentionItem.new(%Run{id: "q1", completed_at: ~U[2026-01-01 09:30:00Z]})

    queue = AttentionQueue.new()
    {result, updated_queue} = AttentionQueue.reconcile(queue, [t1, t2, t3, q1])

    keys = Enum.map(result, & &1.key)
    assert keys == ["run:t2", "run:q1", "run:t1", "run:t3"]
    assert updated_queue.has_seeded
    assert updated_queue.tick == 0
    assert updated_queue.items == result

    # waiting_since returns natural created at for cold-start items
    assert AttentionQueue.waiting_since(updated_queue, "run:t2") == ~U[2026-01-01 09:00:00Z]
    assert AttentionQueue.waiting_since(updated_queue, t2) == ~U[2026-01-01 09:00:00Z]
    assert is_nil(AttentionQueue.waiting_since(updated_queue, "unknown"))
  end

  test "newly arrived item in subsequent reconcile lands at the bottom" do
    now1 = ~U[2026-01-01 12:00:00Z]
    now2 = ~U[2026-01-01 12:05:00Z]
    ref = :atomics.new(1, [])
    :atomics.put(ref, 1, 1)

    clock = fn ->
      case :atomics.get(ref, 1) do
        1 -> now1
        _other -> now2
      end
    end

    queue = AttentionQueue.new(clock: clock)

    t1 = RunAttentionItem.new(%Run{id: "t1", completed_at: ~U[2026-01-01 10:00:00Z]})
    t2 = RunAttentionItem.new(%Run{id: "t2", completed_at: ~U[2026-01-01 09:00:00Z]})
    t3 = RunAttentionItem.new(%Run{id: "t3", completed_at: ~U[2026-01-01 11:00:00Z]})

    {first, queue} = AttentionQueue.reconcile(queue, [t1, t2, t3])
    assert Enum.map(first, & &1.key) == ["run:t2", "run:t1", "run:t3"]
    assert queue.tick == 0

    # Advance clock
    :atomics.put(ref, 1, 2)

    # t4 has an older createdAt than t3, but arrived in a later batch
    t4 = RunAttentionItem.new(%Run{id: "t4", completed_at: ~U[2026-01-01 08:00:00Z]})
    {second, queue} = AttentionQueue.reconcile(queue, [t1, t2, t3, t4])

    assert Enum.map(second, & &1.key) == ["run:t2", "run:t1", "run:t3", "run:t4"]
    assert queue.tick == 1
    # warm arrival gets clock time
    assert AttentionQueue.waiting_since(queue, "run:t4") == now2
    # cold start items retained their original waiting_since
    assert AttentionQueue.waiting_since(queue, "run:t2") == ~U[2026-01-01 09:00:00Z]
  end

  test "questions and tasks interleave by arrival order" do
    queue = AttentionQueue.new()

    t1 = RunAttentionItem.new(%Run{id: "t1", completed_at: ~U[2026-01-01 10:00:00Z]})
    {step1, queue} = AttentionQueue.reconcile(queue, [t1])
    assert Enum.map(step1, & &1.key) == ["run:t1"]

    q1 = RunAttentionItem.new(%Run{id: "q1", completed_at: ~U[2026-01-01 12:00:00Z]})
    {step2, queue} = AttentionQueue.reconcile(queue, [t1, q1])
    assert Enum.map(step2, & &1.key) == ["run:t1", "run:q1"]

    t2 = RunAttentionItem.new(%Run{id: "t2", completed_at: ~U[2026-01-01 08:00:00Z]})
    {step3, queue} = AttentionQueue.reconcile(queue, [t1, q1, t2])
    assert Enum.map(step3, & &1.key) == ["run:t1", "run:q1", "run:t2"]

    q2 = RunAttentionItem.new(%Run{id: "q2", completed_at: ~U[2026-01-01 07:00:00Z]})
    {step4, _queue} = AttentionQueue.reconcile(queue, [t1, q1, t2, q2])
    assert Enum.map(step4, & &1.key) == ["run:t1", "run:q1", "run:t2", "run:q2"]
  end

  test "reconcile is idempotent when waiting set is unchanged" do
    t1 = RunAttentionItem.new(%Run{id: "t1", completed_at: ~U[2026-01-01 10:00:00Z]})
    t2 = RunAttentionItem.new(%Run{id: "t2", completed_at: ~U[2026-01-01 11:00:00Z]})

    queue = AttentionQueue.new()
    {res1, queue} = AttentionQueue.reconcile(queue, [t1, t2])
    {res2, queue} = AttentionQueue.reconcile(queue, [t1, t2])
    {res3, _queue} = AttentionQueue.reconcile(queue, [t1, t2])

    assert Enum.map(res1, & &1.key) == Enum.map(res2, & &1.key)
    assert Enum.map(res2, & &1.key) == Enum.map(res3, & &1.key)
  end

  test "a run changing underneath does not change its position in the queue" do
    run1 = %Run{id: "t1", completed_at: ~U[2026-01-01 10:00:00Z]}
    run2 = %Run{id: "t2", completed_at: ~U[2026-01-01 11:00:00Z]}

    queue = AttentionQueue.new()
    {_items, queue} = AttentionQueue.reconcile(queue, [RunAttentionItem.new(run1), RunAttentionItem.new(run2)])

    changed = %{run1 | error: "Something broke", status: :failed}

    {updated, _queue} =
      AttentionQueue.reconcile(queue, [RunAttentionItem.new(changed), RunAttentionItem.new(run2)])

    assert Enum.map(updated, & &1.key) == ["run:t1", "run:t2"]
  end

  test "resolving an item removes only that item, leaving remaining order intact" do
    t1 = RunAttentionItem.new(%Run{id: "t1", completed_at: ~U[2026-01-01 10:00:00Z]})
    t2 = RunAttentionItem.new(%Run{id: "t2", completed_at: ~U[2026-01-01 11:00:00Z]})
    t3 = RunAttentionItem.new(%Run{id: "t3", completed_at: ~U[2026-01-01 12:00:00Z]})

    queue = AttentionQueue.new()
    {_items, queue} = AttentionQueue.reconcile(queue, [t1, t2, t3])

    # Resolve t2
    {remaining, queue} = AttentionQueue.reconcile(queue, [t1, t3])
    assert Enum.map(remaining, & &1.key) == ["run:t1", "run:t3"]
    assert is_nil(AttentionQueue.waiting_since(queue, "run:t2"))
  end

  test "an item that leaves and comes back later gets a fresh tick and lands at the bottom" do
    t1 = RunAttentionItem.new(%Run{id: "t1", completed_at: ~U[2026-01-01 10:00:00Z]})
    t2 = RunAttentionItem.new(%Run{id: "t2", completed_at: ~U[2026-01-01 11:00:00Z]})
    t3 = RunAttentionItem.new(%Run{id: "t3", completed_at: ~U[2026-01-01 12:00:00Z]})

    queue = AttentionQueue.new()
    {_items, queue} = AttentionQueue.reconcile(queue, [t1, t2, t3])

    # t1 leaves
    {_items, queue} = AttentionQueue.reconcile(queue, [t2, t3])

    # t1 comes back
    {after_return, _queue} = AttentionQueue.reconcile(queue, [t2, t3, t1])
    assert Enum.map(after_return, & &1.key) == ["run:t2", "run:t3", "run:t1"]
  end

  test "items arriving together in a subsequent reconcile tie-break by createdAt oldest first" do
    t1 = RunAttentionItem.new(%Run{id: "t1", completed_at: ~U[2026-01-01 10:00:00Z]})
    queue = AttentionQueue.new()
    {_items, queue} = AttentionQueue.reconcile(queue, [t1])

    t2 = RunAttentionItem.new(%Run{id: "t2", completed_at: ~U[2026-01-01 12:00:00Z]})
    t3 = RunAttentionItem.new(%Run{id: "t3", completed_at: ~U[2026-01-01 11:00:00Z]})

    {res, _queue} = AttentionQueue.reconcile(queue, [t1, t2, t3])
    assert Enum.map(res, & &1.key) == ["run:t1", "run:t3", "run:t2"]
  end

  test "items arriving together with identical createdAt tie-break by key ascending" do
    queue = AttentionQueue.new()
    same_time = ~U[2026-01-01 10:00:00Z]

    t_b = RunAttentionItem.new(%Run{id: "b", completed_at: same_time})
    t_a = RunAttentionItem.new(%Run{id: "a", completed_at: same_time})

    {res, _queue} = AttentionQueue.reconcile(queue, [t_b, t_a])
    assert Enum.map(res, & &1.key) == ["run:a", "run:b"]
  end

  test "reconcile_items/2 and reconcile_queue/2 and Enumerable inputs" do
    t1 = RunAttentionItem.new(%Run{id: "t1", completed_at: ~U[2026-01-01 10:00:00Z]})
    t2 = RunAttentionItem.new(%Run{id: "t2", completed_at: ~U[2026-01-01 11:00:00Z]})

    queue = AttentionQueue.new()

    # Pass MapSet as enumerable
    waiting_set = MapSet.new([t1, t2])
    items = AttentionQueue.reconcile_items(queue, waiting_set)
    assert Enum.map(items, & &1.key) == ["run:t1", "run:t2"]

    updated_q = AttentionQueue.reconcile_queue(queue, [t1, t2])
    assert updated_q.has_seeded
    assert Enum.map(updated_q.items, & &1.key) == ["run:t1", "run:t2"]
  end
end
