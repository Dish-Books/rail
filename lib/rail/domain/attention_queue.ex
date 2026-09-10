defmodule Rail.Domain.TaskAttentionItem do
  @moduledoc """
  An attention item representing a task waiting for human decision.
  """
  @enforce_keys [:key, :waiting_since, :task]
  defstruct [:key, :waiting_since, :task]

  @type t :: %__MODULE__{
          key: String.t(),
          waiting_since: DateTime.t(),
          task: map() | struct()
        }

  @doc "Creates a new TaskAttentionItem from a task map or struct."
  def new(task, opts \\ []) do
    id = (is_map(task) && (Map.get(task, :id) || Map.get(task, "id"))) || nil
    key = Keyword.get(opts, :key, "task:#{id}")

    waiting_since =
      Keyword.get(opts, :waiting_since) ||
        (is_map(task) &&
           (Map.get(task, :created_at) || Map.get(task, :inserted_at) || Map.get(task, "created_at") ||
              Map.get(task, "inserted_at"))) ||
        DateTime.utc_now()

    %__MODULE__{
      key: key,
      waiting_since: waiting_since,
      task: task
    }
  end
end

defmodule Rail.Domain.QuestionAttentionItem do
  @moduledoc """
  An attention item representing an agent question waiting for human decision.
  """
  @enforce_keys [:key, :waiting_since, :question]
  defstruct [:key, :waiting_since, :question]

  @type t :: %__MODULE__{
          key: String.t(),
          waiting_since: DateTime.t(),
          question: map() | struct()
        }

  @doc "Creates a new QuestionAttentionItem from a question map or struct."
  def new(question, opts \\ []) do
    id = (is_map(question) && (Map.get(question, :id) || Map.get(question, "id"))) || nil
    key = Keyword.get(opts, :key, "question:#{id}")

    waiting_since =
      Keyword.get(opts, :waiting_since) ||
        (is_map(question) &&
           (Map.get(question, :created_at) || Map.get(question, :inserted_at) ||
              Map.get(question, "created_at") || Map.get(question, "inserted_at"))) ||
        DateTime.utc_now()

    %__MODULE__{
      key: key,
      waiting_since: waiting_since,
      question: question
    }
  end
end

defmodule Rail.Domain.AttentionQueue.TaskAttentionItem do
  @moduledoc false
  defdelegate new(task, opts \\ []), to: Rail.Domain.TaskAttentionItem
end

defmodule Rail.Domain.AttentionQueue.QuestionAttentionItem do
  @moduledoc false
  defdelegate new(question, opts \\ []), to: Rail.Domain.QuestionAttentionItem
end

defprotocol Rail.Domain.AttentionItem do
  @moduledoc """
  Protocol for items waiting on human decision in the attention queue.
  """
  @fallback_to_any true

  @doc "Returns the unique key for the item (e.g. 'task:id' or 'question:id')."
  def key(item)

  @doc "Returns the timestamp when this item started waiting."
  def waiting_since(item)
end

defimpl Rail.Domain.AttentionItem, for: Rail.Domain.TaskAttentionItem do
  def key(item), do: item.key
  def waiting_since(item), do: item.waiting_since
end

defimpl Rail.Domain.AttentionItem, for: Rail.Domain.QuestionAttentionItem do
  def key(item), do: item.key
  def waiting_since(item), do: item.waiting_since
end

defimpl Rail.Domain.AttentionItem, for: Map do
  def key(%{key: key}) when is_binary(key), do: key
  def key(%{id: id}), do: "task:#{id}"
  def key(%{task: %{id: id}}), do: "task:#{id}"
  def key(%{question: %{id: id}}), do: "question:#{id}"
  def key(_item), do: "item:unknown"

  def waiting_since(%{waiting_since: %DateTime{} = ws}), do: ws
  def waiting_since(%{created_at: %DateTime{} = ca}), do: ca
  def waiting_since(%{inserted_at: %DateTime{} = ia}), do: ia
  def waiting_since(%{task: %{created_at: %DateTime{} = ca}}), do: ca
  def waiting_since(%{task: %{inserted_at: %DateTime{} = ia}}), do: ia
  def waiting_since(%{question: %{created_at: %DateTime{} = ca}}), do: ca
  def waiting_since(%{question: %{inserted_at: %DateTime{} = ia}}), do: ia
  def waiting_since(_item), do: DateTime.utc_now()
end

defimpl Rail.Domain.AttentionItem, for: Any do
  def key(item), do: "item:#{inspect(item)}"
  def waiting_since(_item), do: DateTime.utc_now()
end

defmodule Rail.Domain.AttentionQueue do
  @moduledoc """
  Remembers arrival order of items waiting on a human decision.

  Newly seen items are stamped with an incrementing tick so the list
  forms a stable oldest-first queue. Items already waiting keep their
  relative order, and items no longer waiting are dropped.
  """

  alias Rail.Domain.AttentionItem

  defstruct arrivals: %{},
            tick: 0,
            has_seeded: false,
            clock: nil,
            items: []

  @type arrival :: %{
          tick: non_neg_integer(),
          natural_created_at: DateTime.t(),
          first_seen_at: DateTime.t()
        }

  @type t :: %__MODULE__{
          arrivals: %{String.t() => arrival()},
          tick: non_neg_integer(),
          has_seeded: boolean(),
          clock: (-> DateTime.t()) | nil,
          items: list()
        }

  @doc """
  Initializes a new AttentionQueue.
  Options:
    - `:clock`: fn returning current `DateTime.t()` (default: `&DateTime.utc_now/0`).
    - `:arrivals`: initial arrivals map (default: `%{}`).
    - `:tick`: initial tick count (default: `0`).
    - `:has_seeded`: initial seeded flag (default: `false`).
  """
  def new(opts \\ []) do
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
    arrivals = Keyword.get(opts, :arrivals, %{})
    tick = Keyword.get(opts, :tick, 0)
    has_seeded = Keyword.get(opts, :has_seeded, false)

    %__MODULE__{
      arrivals: arrivals,
      tick: tick,
      has_seeded: has_seeded,
      clock: clock,
      items: []
    }
  end

  @doc """
  Returns when the item with `key` started waiting, or nil if unknown.
  Accepts either a string key or an item struct.
  """
  def waiting_since(%__MODULE__{arrivals: arrivals}, key) when is_binary(key) do
    case Map.get(arrivals, key) do
      %{first_seen_at: first_seen_at} -> first_seen_at
      nil -> nil
    end
  end

  def waiting_since(%__MODULE__{} = queue, item) do
    waiting_since(queue, key_for(item))
  end

  @doc """
  Reconciles the queue with the currently waiting items.

  Drops keys no longer waiting, stamps new arrivals with a strictly higher tick
  (or shares tick 0 on cold start), and returns `{sorted_items, updated_queue}`.
  """
  def reconcile(%__MODULE__{} = queue, waiting) when is_list(waiting) do
    waiting_keys = MapSet.new(Enum.map(waiting, &key_for/1))

    # 1. Drop keys no longer waiting
    pruned_arrivals =
      Map.filter(queue.arrivals, fn {key, _arrival} ->
        MapSet.member?(waiting_keys, key)
      end)

    # 2. Identify new items
    new_items =
      Enum.filter(waiting, fn item ->
        not Map.has_key?(pruned_arrivals, key_for(item))
      end)

    # 3. Handle ticks and first_seen_at
    {updated_arrivals, new_tick, new_has_seeded} =
      if new_items == [] do
        {pruned_arrivals, queue.tick, queue.has_seeded}
      else
        was_seeded = queue.has_seeded
        tick = if was_seeded, do: queue.tick + 1, else: queue.tick
        now = queue.clock.()

        arrivals =
          Enum.reduce(new_items, pruned_arrivals, fn item, acc ->
            key = key_for(item)
            natural_created_at = waiting_since_for(item)
            first_seen_at = if was_seeded, do: now, else: natural_created_at

            Map.put(acc, key, %{
              tick: tick,
              natural_created_at: natural_created_at,
              first_seen_at: first_seen_at
            })
          end)

        {arrivals, tick, true}
      end

    # 4. Stable sort: (tick asc, natural_created_at asc, key asc)
    sorted_items =
      Enum.sort(waiting, fn a, b ->
        key_a = key_for(a)
        key_b = key_for(b)
        arr_a = Map.fetch!(updated_arrivals, key_a)
        arr_b = Map.fetch!(updated_arrivals, key_b)

        compare_arrivals(arr_a, arr_b, key_a, key_b)
      end)

    updated_queue = %{
      queue
      | arrivals: updated_arrivals,
        tick: new_tick,
        has_seeded: new_has_seeded,
        items: sorted_items
    }

    {sorted_items, updated_queue}
  end

  def reconcile(%__MODULE__{} = queue, waiting) do
    reconcile(queue, Enum.to_list(waiting))
  end

  @doc """
  Convenience helper that calls `reconcile/2` and returns just the sorted items.
  """
  def reconcile_items(%__MODULE__{} = queue, waiting) do
    {items, _queue} = reconcile(queue, waiting)
    items
  end

  @doc """
  Convenience helper that calls `reconcile/2` and returns just the updated queue.
  """
  def reconcile_queue(%__MODULE__{} = queue, waiting) do
    {_items, updated_queue} = reconcile(queue, waiting)
    updated_queue
  end

  defp key_for(item), do: AttentionItem.key(item)

  defp waiting_since_for(item), do: AttentionItem.waiting_since(item)

  defp compare_arrivals(arr_a, arr_b, key_a, key_b) do
    cond do
      arr_a.tick < arr_b.tick ->
        true

      arr_a.tick > arr_b.tick ->
        false

      true ->
        case DateTime.compare(arr_a.natural_created_at, arr_b.natural_created_at) do
          :lt -> true
          :gt -> false
          :eq -> key_a <= key_b
        end
    end
  end
end
