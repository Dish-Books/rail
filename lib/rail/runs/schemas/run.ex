defmodule Rail.Runs.Schemas.Run do
  @moduledoc """
  Schema for an individual OS process executing an agent role run.
  """
  use Rail.Schema

  alias Rail.Domain.Enums.RunKind
  alias Rail.Domain.Enums.RunStatus
  alias Rail.Runs.Schemas.RoleRun

  @primary_key {:id, UXID, autogenerate: true, prefix: "run"}
  schema "runs" do
    belongs_to :role_run, RoleRun
    field :task_id, UXID
    field :kind, RunKind
    field :os_pid, :integer
    field :stream_path, :string
    field :node, :string
    field :boot_id, :string
    field :status, RunStatus
    field :started_at, :utc_datetime_usec

    timestamps()
  end

  @cast_fields [
    :role_run_id,
    :task_id,
    :kind,
    :os_pid,
    :stream_path,
    :node,
    :boot_id,
    :status,
    :started_at
  ]

  @required_fields [
    :role_run_id,
    :task_id,
    :kind,
    :stream_path,
    :node,
    :boot_id,
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

  @doc """
  Builds a valid fixture struct for tests.
  """
  def factory do
    %__MODULE__{
      role_run_id: UXID.generate!(prefix: "rr"),
      task_id: UXID.generate!(prefix: "tsk"),
      kind: :stage,
      stream_path: "/tmp/axis/streams/test.ndjson",
      node: to_string(Node.self()),
      boot_id: UXID.generate!(),
      status: :starting,
      started_at: DateTime.utc_now()
    }
  end
end
