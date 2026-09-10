defmodule Rail.Domain.WaitingRow do
  @moduledoc "A row waiting for human action in the Overview queue."
  @enforce_keys [:item, :kind, :waiting_since]
  defstruct [:item, :kind, :waiting_since, :question, :task]

  @type t :: %__MODULE__{
          item: any(),
          kind: :question | :approval | :failed | :ready_to_merge | :conflicts,
          waiting_since: DateTime.t() | nil,
          question: map() | struct() | nil,
          task: map() | struct() | nil
        }
end

defmodule Rail.Domain.AgentRow do
  @moduledoc "A row for a task currently being processed by an agent."
  @enforce_keys [:task]
  defstruct [:task]

  @type t :: %__MODULE__{
          task: map() | struct()
        }
end

defmodule Rail.Domain.SingleCardBlock do
  @moduledoc "A block rendering a single non-compact card in the waiting queue."
  @enforce_keys [:row]
  defstruct [:row]

  @type t :: %__MODULE__{
          row: Rail.Domain.WaitingRow.t()
        }
end

defmodule Rail.Domain.CompactStripBlock do
  @moduledoc "A block grouping consecutive compact rows into a strip."
  @enforce_keys [:rows]
  defstruct [:rows]

  @type t :: %__MODULE__{
          rows: list(Rail.Domain.WaitingRow.t())
        }
end

defmodule Rail.Domain.OverviewQueueState do
  @moduledoc "The complete state of the Overview queue."
  @enforce_keys [:waiting, :with_agent]
  defstruct [:waiting, :with_agent]

  @type t :: %__MODULE__{
          waiting:
            list(
              Rail.Domain.SingleCardBlock.t()
              | Rail.Domain.CompactStripBlock.t()
            ),
          with_agent: list(Rail.Domain.AgentRow.t())
        }
end

defmodule Rail.Domain.OverviewQueue.WaitingRow do
  @moduledoc false
  @enforce_keys [:item, :kind, :waiting_since]
  defstruct [:item, :kind, :waiting_since, :question, :task]
end

defmodule Rail.Domain.OverviewQueue.AgentRow do
  @moduledoc false
  @enforce_keys [:task]
  defstruct [:task]
end

defmodule Rail.Domain.OverviewQueue.SingleCardBlock do
  @moduledoc false
  @enforce_keys [:row]
  defstruct [:row]
end

defmodule Rail.Domain.OverviewQueue.CompactStripBlock do
  @moduledoc false
  @enforce_keys [:rows]
  defstruct [:rows]
end

defmodule Rail.Domain.OverviewQueue.State do
  @moduledoc false
  @enforce_keys [:waiting, :with_agent]
  defstruct [:waiting, :with_agent]
end

defmodule Rail.Domain.OverviewQueue do
  @moduledoc """
  Builds the Overview screen queue state from waiting attention items, all tasks,
  and question/waitingSince lookups.
  """

  alias Rail.Domain.AgentRow
  alias Rail.Domain.AttentionItem
  alias Rail.Domain.CompactStripBlock
  alias Rail.Domain.OverviewQueueState
  alias Rail.Domain.QuestionAttentionItem
  alias Rail.Domain.SingleCardBlock
  alias Rail.Domain.TaskAttentionItem
  alias Rail.Domain.WaitingRow

  @doc """
  Builds the Overview queue state. Accepts either keyword list/map or 4 arguments:
  `waiting`, `tasks`, `question_for`, `waiting_since`.
  """
  def build_overview_queue(opts) when is_list(opts) do
    waiting = Keyword.get(opts, :waiting, [])
    tasks = Keyword.get(opts, :tasks, [])
    question_for = Keyword.get(opts, :question_for, fn _task -> nil end)
    waiting_since = Keyword.get(opts, :waiting_since, fn _key -> nil end)

    build_overview_queue(waiting, tasks, question_for, waiting_since)
  end

  def build_overview_queue(opts) when is_map(opts) do
    waiting = Map.get(opts, :waiting) || Map.get(opts, "waiting") || []
    tasks = Map.get(opts, :tasks) || Map.get(opts, "tasks") || []
    question_for = Map.get(opts, :question_for) || Map.get(opts, "question_for") || fn _task -> nil end
    waiting_since = Map.get(opts, :waiting_since) || Map.get(opts, "waiting_since") || fn _key -> nil end

    build_overview_queue(waiting, tasks, question_for, waiting_since)
  end

  def build_overview_queue(waiting, tasks, question_for, waiting_since) do
    waiting_rows =
      Enum.map(waiting, fn item ->
        task = task_for_item(item)
        question = question_for_item(item, task, question_for)
        kind = waiting_kind_for(task, question)
        key = key_for(item)
        since = waiting_since.(key) || waiting_since_for(item)

        %WaitingRow{
          item: item,
          kind: kind,
          waiting_since: since,
          question: question,
          task: task
        }
      end)

    waiting_blocks = group_waiting_blocks(waiting_rows)

    with_agent_tasks =
      tasks
      |> Enum.filter(fn t -> not merged?(t) and not needs_attention?(t) end)
      |> Enum.sort(fn a, b ->
        time_a = get_field(a, :updated_at) || get_field(a, :inserted_at) || get_field(a, :created_at)
        time_b = get_field(b, :updated_at) || get_field(b, :inserted_at) || get_field(b, :created_at)

        case {time_a, time_b} do
          {%DateTime{} = dt_a, %DateTime{} = dt_b} ->
            DateTime.compare(dt_a, dt_b) in [:gt, :eq]

          {%DateTime{}, nil} ->
            true

          {nil, %DateTime{}} ->
            false

          _other ->
            true
        end
      end)

    with_agent_rows = Enum.map(with_agent_tasks, fn t -> %AgentRow{task: t} end)

    %OverviewQueueState{
      waiting: waiting_blocks,
      with_agent: with_agent_rows
    }
  end

  @doc """
  Determines the waiting kind (:question, :approval, :failed, :ready_to_merge, :conflicts)
  for a task and optional pending question.
  """
  def waiting_kind_for(task, question) do
    cond do
      question != nil or is_nil(task) ->
        :question

      stage_state(task) == :awaiting_approval and stage(task) != :ready_to_merge and not conflicted?(task) ->
        :approval

      stage_state(task) == :failed ->
        :failed

      stage(task) == :ready_to_merge ->
        :ready_to_merge

      conflicted?(task) ->
        :conflicts

      true ->
        :approval
    end
  end

  @doc """
  Returns true if the waiting kind renders as a compact strip row rather than an individual card.
  Compact kinds are :failed, :ready_to_merge, :conflicts.
  """
  def compact_kind?(:failed), do: true
  def compact_kind?(:ready_to_merge), do: true
  def compact_kind?(:conflicts), do: true
  def compact_kind?("failed"), do: true
  def compact_kind?("ready_to_merge"), do: true
  def compact_kind?("conflicts"), do: true
  def compact_kind?(_other), do: false

  @doc """
  Returns true if the task is merged.
  """
  def merged?(task) do
    get_field(task, :is_merged) == true or
      stage(task) == :merged or
      get_field(task, :merged_at) != nil
  end

  @doc """
  Returns true if the task requires human attention.
  """
  def needs_attention?(task) do
    case get_field(task, :needs_attention) do
      bool when is_boolean(bool) ->
        bool

      nil ->
        not merged?(task) and
          not busy?(task) and
          ((stage(task) == :ready_to_merge and not rebasing?(task)) or
             stage_state(task) in [:awaiting_approval, :failed, :blocked, :paused_question, :blocked_rework] or
             (conflicted?(task) and not rebasing?(task)))
    end
  end

  @doc """
  Returns true if the task has merge conflicts.
  """
  def conflicted?(task) do
    cond do
      get_field(task, :shows_as_conflicted) == true ->
        true

      get_field(task, :conflicted) == true ->
        true

      get_field(task, :has_merge_conflicts) == true and not rebasing?(task) ->
        stage_state(task) in [:queued, :awaiting_approval, nil]

      get_field(task, :mergeability) in [:conflicts, "conflicts", :conflicting, "conflicting"] and
          not rebasing?(task) ->
        stage_state(task) in [:queued, :awaiting_approval, nil]

      true ->
        false
    end
  end

  # Private Helpers

  defp task_for_item(%TaskAttentionItem{task: task}), do: task
  defp task_for_item(%QuestionAttentionItem{}), do: nil
  defp task_for_item(%{task: task}), do: task
  defp task_for_item(%{question: _question}), do: nil
  defp task_for_item(_other), do: nil

  defp question_for_item(%QuestionAttentionItem{question: question}, _task, _fun), do: question
  defp question_for_item(%TaskAttentionItem{task: task}, _task, question_for), do: question_for.(task)
  defp question_for_item(%{question: question}, _task, _fun), do: question
  defp question_for_item(%{task: task}, _task, question_for), do: question_for.(task)
  defp question_for_item(_item, _task, _fun), do: nil

  defp key_for(item), do: AttentionItem.key(item)
  defp waiting_since_for(item), do: AttentionItem.waiting_since(item)

  defp group_waiting_blocks(waiting_rows) do
    {blocks_rev, pending_compact} =
      Enum.reduce(waiting_rows, {[], []}, fn row, {blocks_acc, compact_acc} ->
        if compact_kind?(row.kind) do
          {blocks_acc, [row | compact_acc]}
        else
          blocks_acc = flush_compact(blocks_acc, compact_acc)
          {[%SingleCardBlock{row: row} | blocks_acc], []}
        end
      end)

    blocks_rev
    |> flush_compact(pending_compact)
    |> Enum.reverse()
  end

  defp flush_compact(blocks_acc, []), do: blocks_acc

  defp flush_compact(blocks_acc, compact_acc) do
    compact_rows = Enum.reverse(compact_acc)
    [%CompactStripBlock{rows: compact_rows} | blocks_acc]
  end

  defp busy?(task), do: get_field(task, :is_busy) == true
  defp rebasing?(task), do: get_field(task, :is_rebasing) == true

  defp stage(task), do: task |> get_field(:stage) |> to_atom()
  defp stage_state(task), do: task |> get_field(:stage_state) |> to_atom()

  defp to_atom(nil), do: nil
  defp to_atom(atom) when is_atom(atom), do: atom

  defp to_atom(string) when is_binary(string) do
    String.to_existing_atom(string)
  rescue
    _error -> nil
  end

  defp to_atom(_other), do: nil

  defp get_field(nil, _field), do: nil
  defp get_field(%_struct_mod{} = struct, field), do: Map.get(struct, field)

  defp get_field(map, field) when is_map(map) do
    case Map.fetch(map, field) do
      {:ok, val} ->
        val

      :error ->
        case Map.fetch(map, to_string(field)) do
          {:ok, val} -> val
          :error -> nil
        end
    end
  end

  defp get_field(_other, _field), do: nil
end
