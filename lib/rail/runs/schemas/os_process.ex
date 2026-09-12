defmodule Rail.Runs.Schemas.OsProcess do
  @moduledoc """
  Schema for one OS process executing an agent run.

  A run spawns a new OS process for each attempt, chat turn, and rebase.

  `is_chat` says who settles the process when it exits: a chat turn rides
  alongside the stage and leaves it alone, everything else settles it.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Runs.Schemas.Run

  @statuses [:starting, :running, :finished, :adopted_dead, :blocked_on_input, :unwatched, :failed]

  @primary_key {:id, UXID, autogenerate: true, prefix: "proc"}
  schema "os_processes" do
    field :is_chat, :boolean, default: false
    field :os_pid, :integer
    field :stream_path, :string
    field :node, :string
    field :status, Ecto.Enum, values: @statuses
    field :started_at, :utc_datetime_usec

    belongs_to :task, Task
    belongs_to :run, Run

    timestamps()
  end

  @cast_fields [
    :run_id,
    :task_id,
    :is_chat,
    :os_pid,
    :stream_path,
    :node,
    :status,
    :started_at
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
