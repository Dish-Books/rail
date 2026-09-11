defmodule Rail.Runs.Schemas.Run do
  @moduledoc """
  Schema for an individual OS process executing an agent role run.
  """
  use Rail.Schema

  alias Rail.Runs.Schemas.RoleRun

  @kinds [:stage, :chat, :rebase, :probe, :improve]
  @statuses [:starting, :running, :finished, :adopted_dead, :blocked_on_input, :unwatched, :failed]

  @primary_key {:id, UXID, autogenerate: true, prefix: "run"}
  schema "runs" do
    field :task_id, UXID
    field :kind, Ecto.Enum, values: @kinds
    field :os_pid, :integer
    field :stream_path, :string
    field :node, :string
    field :status, Ecto.Enum, values: @statuses
    field :started_at, :utc_datetime_usec

    belongs_to :role_run, RoleRun

    timestamps()
  end

  @cast_fields [
    :role_run_id,
    :task_id,
    :kind,
    :os_pid,
    :stream_path,
    :node,
    :status,
    :started_at
  ]

  @required_fields [
    :role_run_id,
    :task_id,
    :kind,
    :stream_path,
    :node,
    :status,
    :started_at
  ]

  @doc """
  Builds a changeset for a run.
  """
  def changeset(run, attrs) do
    run
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:role_run_id)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses
end
