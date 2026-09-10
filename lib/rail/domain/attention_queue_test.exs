defmodule Rail.Domain.AttentionQueueTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.AttentionItem
  alias Rail.Domain.AttentionQueue
  alias Rail.Domain.QuestionAttentionItem
  alias Rail.Domain.TaskAttentionItem

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
        arrivals: %{"task:1" => %{tick: 5, natural_created_at: fixed_time, first_seen_at: fixed_time}}
      )

    assert custom_q.tick == 5
    assert custom_q.has_seeded
    assert custom_q.clock.() == fixed_time
    assert Map.has_key?(custom_q.arrivals, "task:1")
  end

  test "TaskAttentionItem and QuestionAttentionItem construction and new/2" do
    t1 = ~U[2026-01-01 10:00:00Z]
    t2 = ~U[2026-01-01 11:00:00Z]

    task_map = %{id: "tsk-1", created_at: t1}
    item1 = TaskAttentionItem.new(task_map)
    assert item1.key == "task:tsk-1"
    assert item1.waiting_since == t1
    assert item1.task == task_map

    item1_custom = TaskAttentionItem.new(task_map, key: "custom:1", waiting_since: t2)
    assert item1_custom.key == "custom:1"
    assert item1_custom.waiting_since == t2

    # Delegate module AttentionQueue.TaskAttentionItem
    item1_del = AttentionQueue.TaskAttentionItem.new(task_map)
    assert item1_del.key == "task:tsk-1"

    task_with_inserted = %{id: "tsk-2", inserted_at: t1}
    item2 = TaskAttentionItem.new(task_with_inserted)
    assert item2.waiting_since == t1

    task_no_time = %{id: "tsk-3"}
    item3 = TaskAttentionItem.new(task_no_time)
    assert is_struct(item3.waiting_since, DateTime)

    # Question Attention Item
    q_map = %{id: "q-1", created_at: t1}
    q_item1 = QuestionAttentionItem.new(q_map)
    assert q_item1.key == "question:q-1"
    assert q_item1.waiting_since == t1
    assert q_item1.question == q_map

    q_item1_custom = QuestionAttentionItem.new(q_map, key: "custom:q1", waiting_since: t2)
    assert q_item1_custom.key == "custom:q1"
    assert q_item1_custom.waiting_since == t2

    # Delegate module AttentionQueue.QuestionAttentionItem
    q_item1_del = AttentionQueue.QuestionAttentionItem.new(q_map)
    assert q_item1_del.key == "question:q-1"

    q_with_inserted = %{id: "q-2", inserted_at: t1}
    q_item2 = QuestionAttentionItem.new(q_with_inserted)
    assert q_item2.waiting_since == t1

    q_no_time = %{id: "q-3"}
    q_item3 = QuestionAttentionItem.new(q_no_time)
    assert is_struct(q_item3.waiting_since, DateTime)
  end

  test "AttentionItem protocol implementations" do
    t1 = ~U[2026-01-01 10:00:00Z]

    task_item = %TaskAttentionItem{key: "task:1", waiting_since: t1, task: %{id: "1"}}
    assert AttentionItem.key(task_item) == "task:1"
    assert AttentionItem.waiting_since(task_item) == t1

    queue_task_item = AttentionQueue.TaskAttentionItem.new(%{id: "2"}, key: "task:2", waiting_since: t1)
    assert AttentionItem.key(queue_task_item) == "task:2"
    assert AttentionItem.waiting_since(queue_task_item) == t1

    q_item = %QuestionAttentionItem{key: "question:1", waiting_since: t1, question: %{id: "1"}}
    assert AttentionItem.key(q_item) == "question:1"
    assert AttentionItem.waiting_since(q_item) == t1

    queue_q_item = AttentionQueue.QuestionAttentionItem.new(%{id: "2"}, key: "question:2", waiting_since: t1)
    assert AttentionItem.key(queue_q_item) == "question:2"
    assert AttentionItem.waiting_since(queue_q_item) == t1

    # Map with key and waiting_since
    map_item = %{key: "custom:key", waiting_since: t1}
    assert AttentionItem.key(map_item) == "custom:key"
    assert AttentionItem.waiting_since(map_item) == t1

    # Map with id and created_at
    map_created = %{id: "xyz", created_at: t1}
    assert AttentionItem.key(map_created) == "task:xyz"
    assert AttentionItem.waiting_since(map_created) == t1

    # Map with id and inserted_at
    map_inserted = %{id: "xyz2", inserted_at: t1}
    assert AttentionItem.key(map_inserted) == "task:xyz2"
    assert AttentionItem.waiting_since(map_inserted) == t1

    # Map fallback
    map_unknown = %{other: "val"}
    assert AttentionItem.key(map_unknown) == "item:unknown"
    assert is_struct(AttentionItem.waiting_since(map_unknown), DateTime)

    # Map with task / question nested maps
    assert AttentionItem.key(%{task: %{id: "t_sub"}}) == "task:t_sub"
    assert AttentionItem.key(%{question: %{id: "q_sub"}}) == "question:q_sub"
    assert AttentionItem.waiting_since(%{task: %{created_at: t1}}) == t1
    assert AttentionItem.waiting_since(%{task: %{inserted_at: t1}}) == t1
    assert AttentionItem.waiting_since(%{question: %{created_at: t1}}) == t1
    assert AttentionItem.waiting_since(%{question: %{inserted_at: t1}}) == t1

    # Any fallback
    uri = URI.parse("https://example.com")
    assert String.starts_with?(AttentionItem.key(uri), "item:")
    assert is_struct(AttentionItem.waiting_since(uri), DateTime)
  end

  test "cold start sorts items by naturalCreatedAt oldest-first" do
    t1 = TaskAttentionItem.new(%{id: "t1", created_at: ~U[2026-01-01 10:00:00Z]})
    # oldest
    t2 = TaskAttentionItem.new(%{id: "t2", created_at: ~U[2026-01-01 09:00:00Z]})
    t3 = TaskAttentionItem.new(%{id: "t3", created_at: ~U[2026-01-01 11:00:00Z]})
    q1 = QuestionAttentionItem.new(%{id: "q1", created_at: ~U[2026-01-01 09:30:00Z]})

    queue = AttentionQueue.new()
    {result, updated_queue} = AttentionQueue.reconcile(queue, [t1, t2, t3, q1])

    keys = Enum.map(result, & &1.key)
    assert keys == ["task:t2", "question:q1", "task:t1", "task:t3"]
    assert updated_queue.has_seeded
    assert updated_queue.tick == 0
    assert updated_queue.items == result

    # waiting_since returns natural created at for cold-start items
    assert AttentionQueue.waiting_since(updated_queue, "task:t2") == ~U[2026-01-01 09:00:00Z]
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

    t1 = TaskAttentionItem.new(%{id: "t1", created_at: ~U[2026-01-01 10:00:00Z]})
    t2 = TaskAttentionItem.new(%{id: "t2", created_at: ~U[2026-01-01 09:00:00Z]})
    t3 = TaskAttentionItem.new(%{id: "t3", created_at: ~U[2026-01-01 11:00:00Z]})

    {first, queue} = AttentionQueue.reconcile(queue, [t1, t2, t3])
    assert Enum.map(first, & &1.key) == ["task:t2", "task:t1", "task:t3"]
    assert queue.tick == 0

    # Advance clock
    :atomics.put(ref, 1, 2)

    # t4 has an older createdAt than t3, but arrived in a later batch
    t4 = TaskAttentionItem.new(%{id: "t4", created_at: ~U[2026-01-01 08:00:00Z]})
    {second, queue} = AttentionQueue.reconcile(queue, [t1, t2, t3, t4])

    assert Enum.map(second, & &1.key) == ["task:t2", "task:t1", "task:t3", "task:t4"]
    assert queue.tick == 1
    # warm arrival gets clock time
    assert AttentionQueue.waiting_since(queue, "task:t4") == now2
    # cold start items retained their original waiting_since
    assert AttentionQueue.waiting_since(queue, "task:t2") == ~U[2026-01-01 09:00:00Z]
  end

  test "questions and tasks interleave by arrival order" do
    queue = AttentionQueue.new()

    t1 = TaskAttentionItem.new(%{id: "t1", created_at: ~U[2026-01-01 10:00:00Z]})
    {step1, queue} = AttentionQueue.reconcile(queue, [t1])
    assert Enum.map(step1, & &1.key) == ["task:t1"]

    q1 = QuestionAttentionItem.new(%{id: "q1", created_at: ~U[2026-01-01 12:00:00Z]})
    {step2, queue} = AttentionQueue.reconcile(queue, [t1, q1])
    assert Enum.map(step2, & &1.key) == ["task:t1", "question:q1"]

    t2 = TaskAttentionItem.new(%{id: "t2", created_at: ~U[2026-01-01 08:00:00Z]})
    {step3, queue} = AttentionQueue.reconcile(queue, [t1, q1, t2])
    assert Enum.map(step3, & &1.key) == ["task:t1", "question:q1", "task:t2"]

    q2 = QuestionAttentionItem.new(%{id: "q2", created_at: ~U[2026-01-01 07:00:00Z]})
    {step4, _queue} = AttentionQueue.reconcile(queue, [t1, q1, t2, q2])
    assert Enum.map(step4, & &1.key) == ["task:t1", "question:q1", "task:t2", "question:q2"]
  end

  test "reconcile is idempotent when waiting set is unchanged" do
    t1 = TaskAttentionItem.new(%{id: "t1", created_at: ~U[2026-01-01 10:00:00Z]})
    t2 = TaskAttentionItem.new(%{id: "t2", created_at: ~U[2026-01-01 11:00:00Z]})

    queue = AttentionQueue.new()
    {res1, queue} = AttentionQueue.reconcile(queue, [t1, t2])
    {res2, queue} = AttentionQueue.reconcile(queue, [t1, t2])
    {res3, _queue} = AttentionQueue.reconcile(queue, [t1, t2])

    assert Enum.map(res1, & &1.key) == Enum.map(res2, & &1.key)
    assert Enum.map(res2, & &1.key) == Enum.map(res3, & &1.key)
  end

  test "mutating task data does not change its position in the queue" do
    task1 = %{id: "t1", created_at: ~U[2026-01-01 10:00:00Z], title: "Task 1"}
    task2 = %{id: "t2", created_at: ~U[2026-01-01 11:00:00Z], title: "Task 2"}

    queue = AttentionQueue.new()
    {_items, queue} = AttentionQueue.reconcile(queue, [TaskAttentionItem.new(task1), TaskAttentionItem.new(task2)])

    # Mutate task1
    task1_mutated = Map.merge(task1, %{error: "Something broke", stage: :review, stage_state: :failed})

    {updated, _queue} =
      AttentionQueue.reconcile(queue, [TaskAttentionItem.new(task1_mutated), TaskAttentionItem.new(task2)])

    assert Enum.map(updated, & &1.key) == ["task:t1", "task:t2"]
  end

  test "resolving an item removes only that item, leaving remaining order intact" do
    t1 = TaskAttentionItem.new(%{id: "t1", created_at: ~U[2026-01-01 10:00:00Z]})
    t2 = TaskAttentionItem.new(%{id: "t2", created_at: ~U[2026-01-01 11:00:00Z]})
    t3 = TaskAttentionItem.new(%{id: "t3", created_at: ~U[2026-01-01 12:00:00Z]})

    queue = AttentionQueue.new()
    {_items, queue} = AttentionQueue.reconcile(queue, [t1, t2, t3])

    # Resolve t2
    {remaining, queue} = AttentionQueue.reconcile(queue, [t1, t3])
    assert Enum.map(remaining, & &1.key) == ["task:t1", "task:t3"]
    assert is_nil(AttentionQueue.waiting_since(queue, "task:t2"))
  end

  test "an item that leaves and comes back later gets a fresh tick and lands at the bottom" do
    t1 = TaskAttentionItem.new(%{id: "t1", created_at: ~U[2026-01-01 10:00:00Z]})
    t2 = TaskAttentionItem.new(%{id: "t2", created_at: ~U[2026-01-01 11:00:00Z]})
    t3 = TaskAttentionItem.new(%{id: "t3", created_at: ~U[2026-01-01 12:00:00Z]})

    queue = AttentionQueue.new()
    {_items, queue} = AttentionQueue.reconcile(queue, [t1, t2, t3])

    # t1 leaves
    {_items, queue} = AttentionQueue.reconcile(queue, [t2, t3])

    # t1 comes back
    {after_return, _queue} = AttentionQueue.reconcile(queue, [t2, t3, t1])
    assert Enum.map(after_return, & &1.key) == ["task:t2", "task:t3", "task:t1"]
  end

  test "items arriving together in a subsequent reconcile tie-break by createdAt oldest first" do
    t1 = TaskAttentionItem.new(%{id: "t1", created_at: ~U[2026-01-01 10:00:00Z]})
    queue = AttentionQueue.new()
    {_items, queue} = AttentionQueue.reconcile(queue, [t1])

    t2 = TaskAttentionItem.new(%{id: "t2", created_at: ~U[2026-01-01 12:00:00Z]})
    t3 = TaskAttentionItem.new(%{id: "t3", created_at: ~U[2026-01-01 11:00:00Z]})

    {res, _queue} = AttentionQueue.reconcile(queue, [t1, t2, t3])
    assert Enum.map(res, & &1.key) == ["task:t1", "task:t3", "task:t2"]
  end

  test "items arriving together with identical createdAt tie-break by key ascending" do
    queue = AttentionQueue.new()
    same_time = ~U[2026-01-01 10:00:00Z]

    t_b = TaskAttentionItem.new(%{id: "b", created_at: same_time})
    t_a = TaskAttentionItem.new(%{id: "a", created_at: same_time})

    {res, _queue} = AttentionQueue.reconcile(queue, [t_b, t_a])
    assert Enum.map(res, & &1.key) == ["task:a", "task:b"]
  end

  test "reconcile_items/2 and reconcile_queue/2 and Enumerable inputs" do
    t1 = TaskAttentionItem.new(%{id: "t1", created_at: ~U[2026-01-01 10:00:00Z]})
    t2 = TaskAttentionItem.new(%{id: "t2", created_at: ~U[2026-01-01 11:00:00Z]})

    queue = AttentionQueue.new()

    # Pass MapSet as enumerable
    waiting_set = MapSet.new([t1, t2])
    items = AttentionQueue.reconcile_items(queue, waiting_set)
    assert Enum.map(items, & &1.key) == ["task:t1", "task:t2"]

    updated_q = AttentionQueue.reconcile_queue(queue, [t1, t2])
    assert updated_q.has_seeded
    assert Enum.map(updated_q.items, & &1.key) == ["task:t1", "task:t2"]
  end
end
