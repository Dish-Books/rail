defmodule Rail.Domain.RunFailure do
  @moduledoc """
  Analyzes run output, exit codes, and error strings.

  Distinguishes `:transient` vs `:permanent` failures per PLAN.md §5 (D4) and spec 01 §21.
  Provides `retryable?/1`, `transient?/1`, and backoff calculation (`retry_delay/1`).
  """
  use Ecto.Schema

  import Ecto.Changeset

  @derive Jason.Encoder

  @types [:transient, :permanent]

  @max_auto_retries 2
  @retry_backoff [15, 60]

  # Reasons a retry cannot help, checked first: several of them mention words
  # that otherwise read as transient (e.g. "try again later" in a billing limit).
  @permanent_patterns [
    ~r/unrecognized_model|unknown model|invalid model/i,
    ~r/no such cli binary|no such file|command not found/i,
    ~r/not authenticated|unauthorized|invalid api key|401/i,
    ~r/usage limit|quota exceeded|insufficient credit|billing/i,
    ~r/permission denied/i
  ]

  @transient_patterns [
    # The harness could not parse the model's own tool call and gave up.
    ~r/improperly formatted function call|malformed function call/i,
    # A child that outlived the app and ended with nobody reading its stream.
    ~r/without reporting a result/i,
    ~r/overloaded|capacity|try again later|temporarily unavailable/i,
    ~r/\b(429|500|502|503|504)\b/,
    ~r/timed out|timeout|deadline exceeded/i,
    ~r/connection (reset|closed|refused|aborted)|econnreset|epipe|socket hang up|stream (disconnected|error)/i,
    ~r/rate limit|rate-limit|rate_limit/i,
    ~r/interrupted socket/i,
    ~r/temporary lock|temporary_lock|lock contention|could not obtain lock/i
  ]

  @primary_key false
  embedded_schema do
    field :type, Ecto.Enum, values: @types, default: :permanent
    field :message, :string
    field :exit_code, :integer
    field :retryable, :boolean, default: false
    field :attempt, :integer, default: 0
  end

  @fields [:type, :message, :exit_code, :retryable, :attempt]

  @doc "Builds a changeset for a RunFailure struct."
  def changeset(run_failure, attrs) do
    run_failure
    |> cast(attrs, @fields)
    |> validate_required([:type])
  end

  @doc "Builds a valid RunFailure fixture struct for testing."
  def factory do
    %__MODULE__{
      type: :transient,
      message: "503 Service Unavailable",
      exit_code: 1,
      retryable: true,
      attempt: 1
    }
  end

  @doc "Returns the maximum number of automatic retries allowed (2)."
  def max_auto_retries, do: @max_auto_retries

  @doc "Returns the retry backoff sequence in seconds ([15, 60])."
  def retry_backoff, do: @retry_backoff

  @doc """
  Whether `message` describes a failure worth an automatic retry.

  Permanent reasons are checked first: if any permanent pattern matches,
  it returns `false` even if transient words are present.
  Any unrecognized or unclassified failure is treated as permanent (`false`).
  """
  def transient?(nil), do: false

  def transient?(%__MODULE__{type: :transient}), do: true
  def transient?(%__MODULE__{type: :permanent}), do: false

  def transient?(message) when is_binary(message) do
    trimmed = String.trim(message)

    cond do
      trimmed == "" ->
        false

      Enum.any?(@permanent_patterns, &Regex.match?(&1, trimmed)) ->
        false

      Enum.any?(@transient_patterns, &Regex.match?(&1, trimmed)) ->
        true

      true ->
        false
    end
  end

  def transient?(_other), do: false

  @doc "Whether `message` describes a permanent failure."
  def permanent?(input), do: not transient?(input)

  @doc """
  Classifies a run failure message and optional exit code into a `RunFailure` struct.
  """
  def classify(attrs) when is_map(attrs) do
    message = attrs[:message] || attrs["message"]
    exit_code = attrs[:exit_code] || attrs["exit_code"]
    attempt = attrs[:attempt] || attrs["attempt"] || 0

    classify_internal(message, exit_code, attempt)
  end

  def classify(message, exit_code \\ nil) do
    classify_internal(message, exit_code, 0)
  end

  @doc """
  Calculates the retry delay in seconds for a given retry attempt.
  - Attempt 1: 15 seconds
  - Attempt 2: 60 seconds
  - Attempt 3+: nil (max retries exceeded)
  """
  def retry_delay(attempt) when is_integer(attempt) do
    case attempt do
      0 -> 15
      1 -> 15
      2 -> 60
      _other -> nil
    end
  end

  def retry_delay(_other), do: nil

  @doc """
  Calculates the retry delay in milliseconds for a given retry attempt.
  """
  def retry_delay_ms(attempt) do
    case retry_delay(attempt) do
      seconds when is_integer(seconds) -> seconds * 1000
      nil -> nil
    end
  end

  @doc """
  Determines if a failure is retryable given the attempt count or failure struct.
  """
  def retryable?(%__MODULE__{retryable: retryable}), do: retryable

  def retryable?(attempt) when is_integer(attempt) do
    attempt < @max_auto_retries
  end

  def retryable?(message) when is_binary(message) do
    transient?(message)
  end

  def retryable?(_other), do: false

  def retryable?(message, attempt) when is_binary(message) and is_integer(attempt) do
    transient?(message) and attempt < @max_auto_retries
  end

  defp classify_internal(message, exit_code, attempt) do
    is_transient = transient?(message)
    type = if is_transient, do: :transient, else: :permanent
    retryable = is_transient and attempt < @max_auto_retries

    %__MODULE__{
      type: type,
      message: message,
      exit_code: exit_code,
      retryable: retryable,
      attempt: attempt
    }
  end
end
