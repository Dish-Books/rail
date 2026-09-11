defmodule Rail.Runs.Schemas.RoleRun do
  @moduledoc """
  Schema for an execution lifecycle of an agent role on a task.
  """
  use Rail.Schema

  alias Rail.Domain.TaskUsage
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent

  @statuses [:starting, :running, :finished, :adopted_dead, :blocked_on_input, :unwatched, :failed]

  @primary_key {:id, UXID, autogenerate: true, prefix: "rr"}
  schema "role_runs" do
    field :task_id, UXID
    field :role_id, UXID
    field :conversation_id, :string
    field :status, Ecto.Enum, values: @statuses
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

    embeds_one :usage, TaskUsage, on_replace: :delete
    embeds_one :chat_usage, TaskUsage, on_replace: :delete

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

  def statuses, do: @statuses

  @doc """
  Returns true if this role run has started execution previously.
  """
  def has_started?(%__MODULE__{} = role_run) do
    is_struct(role_run.started_at, DateTime) or (role_run.attempts || 0) > 0
  end

  def has_started?(_other), do: false

  @doc """
  Returns true if this role run holds a conversation an agent can be resumed into.

  A pending answer only means "continue where you stopped" when there is a
  conversation to continue: without one the agent never saw the question, so the
  answer would reach a fresh process with no history.
  """
  def resumable?(%__MODULE__{conversation_id: conversation_id}) when is_binary(conversation_id) do
    String.trim(conversation_id) != ""
  end

  def resumable?(_other), do: false

  @doc """
  Returns true if this role run can accept an interactive chat turn:
  it must have previously started and carry a non-empty conversation ID.
  """
  def can_chat?(%__MODULE__{} = role_run) do
    has_started?(role_run) and
      is_binary(role_run.conversation_id) and
      String.trim(role_run.conversation_id) != ""
  end

  def can_chat?(_other), do: false

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
