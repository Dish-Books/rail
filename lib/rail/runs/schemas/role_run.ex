defmodule Rail.Runs.Schemas.RoleRun do
  @moduledoc """
  Schema for an execution lifecycle of an agent role on a task.
  """
  use Rail.Schema

  alias Rail.Domain.Enums.RunStatus
  alias Rail.Domain.TaskUsage
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent

  @primary_key {:id, UXID, autogenerate: true, prefix: "rr"}
  schema "role_runs" do
    field :task_id, UXID
    field :role_id, UXID
    field :conversation_id, :string
    field :status, RunStatus
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :exit_code, :integer
    field :output, :string
    field :error, :string
    field :pending_answer, :string
    field :pending_chat, :string
    field :attempts, :integer, default: 0
    field :attempt_log_lines, :integer, default: 0
    field :auto_retries, :integer, default: 0
    field :pruned, :boolean, default: false
    field :chat_fingerprint_head_sha, :string
    field :chat_fingerprint_dirty_digest, :string
    field :stage_fingerprint_head_sha, :string
    field :stage_fingerprint_dirty_digest, :string

    embeds_one :usage, TaskUsage, on_replace: :update
    embeds_one :chat_usage, TaskUsage, on_replace: :update

    has_many :runs, Run
    has_many :run_events, RunEvent

    timestamps()
  end

  @cast_fields [
    :task_id,
    :role_id,
    :conversation_id,
    :status,
    :started_at,
    :completed_at,
    :exit_code,
    :output,
    :error,
    :pending_answer,
    :pending_chat,
    :attempts,
    :attempt_log_lines,
    :auto_retries,
    :pruned,
    :chat_fingerprint_head_sha,
    :chat_fingerprint_dirty_digest,
    :stage_fingerprint_head_sha,
    :stage_fingerprint_dirty_digest
  ]

  @required_fields [
    :task_id,
    :role_id,
    :status,
    :started_at
  ]

  @doc """
  Builds a changeset for a role run.
  """
  def changeset(role_run, attrs) do
    changeset =
      role_run
      |> cast(attrs, @cast_fields)
      |> validate_required(@required_fields)

    changeset
    |> handle_embed(:usage, attrs)
    |> handle_embed(:chat_usage, attrs)
  end

  @doc """
  Builds a valid fixture struct for tests.
  """
  def factory do
    %__MODULE__{
      task_id: UXID.generate!(prefix: "tsk"),
      role_id: UXID.generate!(prefix: "rol"),
      status: :running,
      started_at: DateTime.utc_now(),
      attempts: 0,
      attempt_log_lines: 0,
      auto_retries: 0,
      pruned: false
    }
  end

  defp handle_embed(changeset, field, attrs) do
    case Map.get(attrs, field) || Map.get(attrs, to_string(field)) do
      %TaskUsage{} = struct ->
        put_embed(changeset, field, struct)

      map when is_map(map) ->
        cast_embed(changeset, field)

      _other ->
        changeset
    end
  end
end
