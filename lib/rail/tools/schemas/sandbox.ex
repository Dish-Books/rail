defmodule Rail.Tools.Schemas.Sandbox do
  @moduledoc """
  A task's sandbox: its disk, which outlives any one container, and the container `rail-runner` runs in while the task
  has work. Every command the task runs is an `OsProcess` under it.

  `:starting` has a container whose runner has not yet said hello and checked the task out; `:running` has one that
  has; `:stopped` has none, its disk kept for the next; `:ended` has neither.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools.Schemas.Backend

  @statuses [:starting, :running, :stopped, :ended]
  @engines [:docker]

  @primary_key {:id, UXID, autogenerate: true, prefix: "sbx"}
  schema "sandboxes" do
    field :host, :string, default: "local"
    field :engine, Ecto.Enum, values: @engines
    field :image, :string
    # Where the task's checkout lives between containers: a Docker volume's name.
    field :volume, :string
    field :status, Ecto.Enum, values: @statuses
    field :container_id, :string
    field :token_hash, :binary, redact: true
    field :runner_version, :string
    field :started_at, :utc_datetime_usec
    field :connected_at, :utc_datetime_usec
    field :ready_at, :utc_datetime_usec
    field :stopped_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    # The account whose login the container mounts, until RAIL-228 proxies it.
    belongs_to :backend, Backend
    belongs_to :task, Task

    timestamps()
  end

  @cast_fields [
    :host,
    :engine,
    :image,
    :volume,
    :status,
    :container_id,
    :token_hash,
    :runner_version,
    :started_at,
    :connected_at,
    :ready_at,
    :stopped_at,
    :ended_at,
    :backend_id
  ]

  @doc "Builds a changeset; `task_id` is set from the task, never cast."
  def changeset(sandbox, attrs) do
    sandbox
    |> cast(attrs, @cast_fields)
    |> validate_required([:task_id, :host, :engine, :image, :volume, :status])
    |> unique_constraint(:task_id, name: :sandboxes_task_id_index)
  end

  @doc "True while it has a container."
  def live?(%__MODULE__{status: status}), do: status in [:starting, :running]
end
