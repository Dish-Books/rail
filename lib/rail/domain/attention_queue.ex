defmodule Rail.Domain.RunAttentionItem do
  @moduledoc """
  A run waiting on a human.

  What is waiting is always a run: the questions it asked, the verdict it stated
  and the failure it hit all belong to it, and the task it carries is context for
  showing them, not the thing that waits.
  """
  alias Rail.Runs.Schemas.Run

  @enforce_keys [:key, :waiting_since, :run]
  defstruct [:key, :waiting_since, :run]

  @type t :: %__MODULE__{key: String.t(), waiting_since: DateTime.t(), run: Run.t()}

  @doc "Wraps `run` as the thing it is waiting as."
  def new(%Run{} = run) do
    %__MODULE__{
      key: "run:#{run.id}",
      waiting_since: run.completed_at || run.updated_at || run.inserted_at,
      run: run
    }
  end
end

defprotocol Rail.Domain.AttentionItem do
  @moduledoc """
  Protocol for items waiting on human decision in the attention queue.
  """

  @doc "Returns the unique key for the item."
  def key(item)

  @doc "Returns the timestamp when this item started waiting."
  def waiting_since(item)
end

defimpl Rail.Domain.AttentionItem, for: Rail.Domain.RunAttentionItem do
  def key(item), do: item.key
  def waiting_since(item), do: item.waiting_since
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
