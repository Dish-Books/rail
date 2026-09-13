defmodule Rail.Domain.WaitingRow do
  @moduledoc "A run waiting for human action in the Overview queue."
  alias Rail.Domain.RunAttentionItem
  alias Rail.Runs.Schemas.Run

  @enforce_keys [:item, :waiting_since, :run]
  defstruct [:item, :waiting_since, :run]

  @type t :: %__MODULE__{
          item: RunAttentionItem.t(),
          waiting_since: DateTime.t() | nil,
          run: Run.t()
        }
end

defmodule Rail.Domain.AgentRow do
  @moduledoc "A row for a run an agent is working on right now."
  alias Rail.Runs.Schemas.Run

  @enforce_keys [:run]
  defstruct [:run]

  @type t :: %__MODULE__{run: Run.t()}
end

defmodule Rail.Domain.OverviewQueueState do
  @moduledoc "The complete state of the Overview queue."
  @enforce_keys [:waiting, :with_agent]
  defstruct [:waiting, :with_agent]

  @type t :: %__MODULE__{
          waiting: list(Rail.Domain.WaitingRow.t()),
          with_agent: list(Rail.Domain.AgentRow.t())
        }
end

defmodule Rail.Domain.OverviewQueue do
  @moduledoc """
  Builds the Overview screen from runs.

  A row is a run. What a run is doing it says itself, and the questions it asked
  hang off it — so nothing here has to work out which run a task means, and a run
  that asked something shows up as itself rather than as the task it belongs to.
  The task each run carries is what a row renders around it: the ticket, the
  branch, the stage it sits at.

  What waits on a human is one thing now: a run blocked on a question. The
  merge, rebase and stage-approval rows went with the stages that raised them.
  """

  alias Rail.Domain.AgentRow
  alias Rail.Domain.AttentionItem
  alias Rail.Domain.OverviewQueueState
  alias Rail.Domain.WaitingRow
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Runs.Schemas.Run

  @doc """
  Builds the Overview queue state from the runs waiting and the runs there are.

  `waiting` is already in arrival order; `waiting_since` answers when each key
  started waiting.
  """
  def build_overview_queue(waiting, runs, waiting_since) do
    %OverviewQueueState{
      waiting:
        Enum.map(waiting, fn %{run: %Run{} = run} = item ->
          %WaitingRow{
            item: item,
            waiting_since: waiting_since.(AttentionItem.key(item)) || AttentionItem.waiting_since(item),
            run: run
          }
        end),
      with_agent: runs |> Enum.filter(&Run.running?/1) |> Enum.sort_by(& &1.started_at, {:desc, DateTime}) |> rows()
    }
  end

  @doc """
  Returns true if this run is waiting on a human at all.

  A blocked run stays blocked until its answers are sent, so it keeps its place
  in the queue while the human works through the batch.
  """
  def needs_attention?(%Run{task: %Task{} = task} = run) do
    task.stage != :merged and is_nil(task.merged_at) and Run.state(run) == :blocked
  end

  defp rows(runs), do: Enum.map(runs, &%AgentRow{run: &1})
end
