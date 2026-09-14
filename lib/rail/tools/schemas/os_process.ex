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
    field :node, :string
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
    :node,
    :status,
    :started_at,
    :mcp_token_hash,
    :stream_offset
  ]

  @required_fields [
    :run_id,
    :task_id,
    :stream_path,
    :node,
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
end
