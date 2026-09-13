defmodule Rail.Pipeline.Schemas.Run do
  @moduledoc """
  Schema for one role's execution on a task: the unit a user calls a run.

  A run outlives the OS processes that carry it out (see OsProcess) -- retries,
  chat turns and rebases each spawn a new one against the same conversation -- and
  owns the whole RunEvent log.
  """
  use Rail.Schema

  import Rail.Pipeline.Utils.CompactNumber

  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools.Schemas.OsProcess

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
    field :stage_fingerprint_head_sha, :string
    field :stage_fingerprint_dirty_digest, :string

    # What the agent has spent getting this far, by kind of token. What that
    # costs is a question for the backend's own billing, not for a run.
    embeds_one :usage, Usage, primary_key: false, on_replace: :delete do
      @derive Jason.Encoder
      field :input_tokens, :integer, default: 0
      field :output_tokens, :integer, default: 0
      field :cache_read_input_tokens, :integer, default: 0
      field :cache_creation_input_tokens, :integer, default: 0
    end

    belongs_to :role, Role
    belongs_to :task, Task

    has_many :os_processes, OsProcess
    has_many :questions, Question
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
    :stage_fingerprint_head_sha,
    :stage_fingerprint_dirty_digest
  ]

  @usage_fields [
    :input_tokens,
    :output_tokens,
    :cache_read_input_tokens,
    :cache_creation_input_tokens
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
      |> validate_conversation_id_unchanged()

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
  What this run has spent, as a compact token count, or nil if it has spent
  nothing yet.

  Accepts a run or a usage record, since a run being followed has its running
  total before it has a row to put it on.
  """
  def usage(%__MODULE__{usage: usage}), do: usage(usage)
  def usage(nil), do: nil

  def usage(%__MODULE__.Usage{} = usage) do
    case total_tokens(usage) do
      0 -> nil
      total -> "#{compact_number(total)} tokens"
    end
  end

  @doc "Every kind of token this usage record counted, added up."
  def total_tokens(%__MODULE__.Usage{} = usage) do
    Enum.reduce(@usage_fields, 0, fn field, total -> total + (Map.fetch!(usage, field) || 0) end)
  end

  @doc """
  Adds what was just spent to what had been spent already.
  """
  def add_usage(nil, %__MODULE__.Usage{} = spent), do: spent

  def add_usage(%__MODULE__.Usage{} = so_far, %__MODULE__.Usage{} = spent) do
    Enum.reduce(@usage_fields, %__MODULE__.Usage{}, fn field, total ->
      Map.put(total, field, (Map.fetch!(so_far, field) || 0) + (Map.fetch!(spent, field) || 0))
    end)
  end

  @doc """
  Returns true if this run is waiting on a human at all.

  A blocked run stays blocked until its answers are sent, so it keeps its place
  in the queue while the human works through the batch.
  """
  def needs_attention?(%__MODULE__{task: %Task{} = task} = run) do
    task.stage != :merged and is_nil(task.merged_at) and state(run) == :blocked
  end

  @doc """
  Since when this run has been waiting on a human.

  A run stops before it waits, so the time it stopped is the time it started
  waiting. The fallbacks cover the moment between a run parking on a question and
  its OS process actually exiting, when nothing has recorded a stop yet.
  """
  def waiting_since(%__MODULE__{} = run) do
    run.completed_at || run.updated_at || run.inserted_at
  end

  @doc """
  Returns true if this run has started execution previously.
  """
  def has_started?(%__MODULE__{} = run) do
    is_struct(run.started_at, DateTime)
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

  # A run is one conversation with one agent. Moving it to another would silently
  # strand everything said so far, so a caller trying it is told rather than
  # having the write dropped underneath it.
  defp validate_conversation_id_unchanged(changeset) do
    case {changeset.data.conversation_id, get_change(changeset, :conversation_id)} do
      {existing, changed} when is_binary(existing) and is_binary(changed) and existing != changed ->
        add_error(changeset, :conversation_id, "is already set and cannot be changed")

      _unset_or_unchanged ->
        changeset
    end
  end

  # Usage accumulates: a run spends across every OS process it spawns, so what
  # arrives here is what the latest one reported, not a new total.
  defp handle_embed(changeset, field, attrs) do
    case Map.get(attrs, field) || Map.get(attrs, to_string(field)) do
      %__MODULE__.Usage{} = spent ->
        put_embed(changeset, field, add_usage(changeset.data.usage, spent))

      map when is_map(map) ->
        cast_embed(changeset, field, with: &usage_changeset/2)

      _other ->
        changeset
    end
  end

  defp usage_changeset(usage, attrs) do
    usage
    |> cast(attrs, @usage_fields)
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:cache_read_input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:cache_creation_input_tokens, greater_than_or_equal_to: 0)
  end
end
