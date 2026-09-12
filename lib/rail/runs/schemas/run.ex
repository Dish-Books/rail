defmodule Rail.Runs.Schemas.Run do
  @moduledoc """
  Schema for one role's execution on a task: the unit a user calls a run.

  A run outlives the OS processes that carry it out (see OsProcess) -- retries,
  chat turns and rebases each spawn a new one against the same conversation -- and
  owns the whole RunEvent log.
  """
  use Rail.Schema

  alias Rail.Domain.TaskUsage
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.RunEvent

  @statuses [:starting, :running, :finished, :adopted_dead, :blocked_on_input, :unwatched, :failed]

  # Whether this run's stage has had its say. A run latches to `:done` when it
  # states a verdict, and `enter_stage/3` puts it back to `:in_progress` when a
  # later stage sends the work here again.
  @stage_outcomes [:in_progress, :done]

  @primary_key {:id, UXID, autogenerate: true, prefix: "run"}
  schema "runs" do
    field :conversation_id, :string
    field :status, Ecto.Enum, values: @statuses
    field :stage_outcome, Ecto.Enum, values: @stage_outcomes, default: :in_progress
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :exit_code, :integer
    field :error, :string
    field :pending_answer, :string
    field :pending_chat, :string
    field :attempts, :integer, default: 0
    field :attempt_log_lines, :integer, default: 0
    field :stage_fingerprint_head_sha, :string
    field :stage_fingerprint_dirty_digest, :string

    embeds_one :usage, TaskUsage, on_replace: :delete

    belongs_to :role, Role
    belongs_to :task, Task

    has_many :os_processes, OsProcess
    has_many :run_events, RunEvent

    timestamps()
  end

  @cast_fields [
    :task_id,
    :role_id,
    :conversation_id,
    :status,
    :stage_outcome,
    :started_at,
    :completed_at,
    :exit_code,
    :error,
    :pending_answer,
    :pending_chat,
    :attempts,
    :attempt_log_lines,
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
  Builds a changeset for a run.
  """
  def changeset(run, attrs) do
    changeset =
      run
      |> cast(attrs, @cast_fields)
      |> validate_required(@required_fields)

    handle_embed(changeset, :usage, attrs)
  end

  def statuses, do: @statuses
  def stage_outcomes, do: @stage_outcomes

  @doc """
  What this run is doing right now, read off the run alone.

  A task has no state of its own: whatever is being shown already holds the run
  it is showing, and this is what that run says about itself. `:stopped` is the
  resting state of a run that is no longer executing and has not said it is
  done — a run the user stopped, and a run that ended without stating a verdict,
  are the same situation and are resolved the same way, by sending a message.

  `nil` reads as `:queued`: a stage with no run has not started.
  """
  def state(%__MODULE__{status: status}) when status in [:starting, :running], do: :running
  def state(%__MODULE__{status: :blocked_on_input}), do: :blocked
  def state(%__MODULE__{stage_outcome: :done}), do: :done
  def state(%__MODULE__{error: error}) when is_binary(error), do: :failed
  def state(%__MODULE__{}), do: :stopped

  # No run for a stage means that stage has not started.
  def state(_nothing_yet), do: :queued

  @doc """
  Returns true if this run is executing right now.
  """
  def running?(%__MODULE__{} = run), do: state(run) == :running
  def running?(_other), do: false

  @doc """
  Returns true if this run has started execution previously.
  """
  def has_started?(%__MODULE__{} = run) do
    is_struct(run.started_at, DateTime) or (run.attempts || 0) > 0
  end

  def has_started?(_other), do: false

  @doc """
  Returns true if this run holds a conversation an agent can be resumed into.

  A pending answer only means "continue where you stopped" when there is a
  conversation to continue: without one the agent never saw the question, so the
  answer would reach a fresh process with no history.
  """
  def resumable?(%__MODULE__{conversation_id: conversation_id}) when is_binary(conversation_id) do
    String.trim(conversation_id) != ""
  end

  def resumable?(_other), do: false

  @doc """
  Returns true if this run can accept an interactive chat turn:
  it must have previously started and carry a non-empty conversation ID.
  """
  def can_chat?(%__MODULE__{} = run) do
    has_started?(run) and
      is_binary(run.conversation_id) and
      String.trim(run.conversation_id) != ""
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
