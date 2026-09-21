defmodule Rail.Tools.Schemas.OsProcess do
  @moduledoc """
  Schema for one OS process executing an agent run.

  A run spawns a new OS process for each attempt, each message, and each rebase.
  They are all the same thing: `run_finished/3` settles every one of them the
  same way, from the row the spawn wrote.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  @statuses [:starting, :running, :finished, :adopted_dead, :blocked_on_input, :unwatched, :failed]

  @primary_key {:id, UXID, autogenerate: true, prefix: "proc"}
  schema "os_processes" do
    field :os_pid, :integer
    field :stream_path, :string
    field :status, Ecto.Enum, values: @statuses
    field :started_at, :utc_datetime_usec
    field :mcp_token_hash, :binary, redact: true

    # How far into the stream the run's log has been written, in bytes, always on
    # a line boundary. Whatever follows this process next starts reading here.
    field :stream_offset, :integer, default: 0

    belongs_to :task, Task
    belongs_to :run, Run

    timestamps()
  end

  @cast_fields [
    :run_id,
    :task_id,
    :os_pid,
    :stream_path,
    :status,
    :started_at,
    :mcp_token_hash,
    :stream_offset
  ]

  @required_fields [
    :run_id,
    :task_id,
    :stream_path,
    :status,
    :started_at
  ]

  @doc """
  Builds a changeset for a run.
  """
  def changeset(os_process, attrs) do
    os_process
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:run_id)
  end

  def statuses, do: @statuses

  @doc """
  How long this process has been going, in seconds.

  One process is one turn of an agent, so this is the whole of what a turn cost
  in time. A process still going is measured to now; one that has stopped is
  measured to when it was last written to, which is the moment its exit was
  recorded — there is no separate finish time, and adding one would only restate
  what the row already says.
  """
  def duration_seconds(os_process, now \\ DateTime.utc_now())

  def duration_seconds(%__MODULE__{started_at: %DateTime{} = started, status: status}, now)
      when status in [:starting, :running] do
    max(0, DateTime.diff(now, started, :second))
  end

  def duration_seconds(%__MODULE__{started_at: %DateTime{} = started, updated_at: %DateTime{} = ended}, _now) do
    max(0, DateTime.diff(ended, started, :second))
  end

  def duration_seconds(%__MODULE__{}, _now), do: 0

  @doc """
  What every one of a run's processes has cost in time, added up.

  A run outlives the processes carrying it — retries and chat turns each spawn a
  new one — so its own `started_at` says when the latest turn began and nothing
  about the rest. This is the figure a reader means by "how long has the agent
  been on this".
  """
  def total_duration_seconds(os_processes, now \\ DateTime.utc_now()) when is_list(os_processes) do
    Enum.reduce(os_processes, 0, fn os_process, total -> total + duration_seconds(os_process, now) end)
  end
end
