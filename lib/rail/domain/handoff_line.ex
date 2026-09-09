defmodule Rail.Domain.HandoffLine do
  @moduledoc """
  A transcript line recording work passed between two roles on one task.

  Attributes:
    - `role_id`: The role at the other end: who sent it, or who it was sent to.
    - `summary`: One-line summary of what was handed over.
    - `timestamp`: When the handoff occurred.
    - `direction`: `:received` (from other role) or `:sent` (to other role).
    - `note`: Optional multi-line body / findings passed with the handoff.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @derive Jason.Encoder

  @directions [:received, :sent]

  @received_marker "←"
  @sent_marker "→"

  # Pattern 1: standard Axis arrow syntax: [handoff ← architect] summary
  @arrow_pattern ~r/^\[handoff ([←→]) ([A-Za-z0-9_-]+)\]\s*(.*)$/u
  # Pattern 2: colon syntax: [handoff: architect] summary
  @colon_pattern ~r/^\[handoff:\s*([A-Za-z0-9_-]+)\]\s*(.*)$/u
  # Pattern 3: explicit direction syntax: [handoff received: architect] or [handoff sent: reviewer]
  @named_direction_pattern ~r/^\[handoff\s+(received|sent):\s*([A-Za-z0-9_-]+)\]\s*(.*)$/ui

  @primary_key false
  embedded_schema do
    field :role_id, :string
    field :summary, :string
    field :timestamp, :utc_datetime_usec
    field :direction, Ecto.Enum, values: @directions, default: :received
    field :note, :string
  end

  @fields [:role_id, :summary, :timestamp, :direction, :note]

  @doc "Builds a changeset for a HandoffLine struct."
  def changeset(handoff_line, attrs) do
    handoff_line
    |> cast(attrs, @fields)
    |> validate_required([:role_id, :summary, :direction])
  end

  @doc "Builds a valid HandoffLine fixture struct for testing."
  def factory do
    %__MODULE__{
      role_id: "architect",
      summary: "Implementation plan ready for review",
      direction: :received,
      timestamp: DateTime.utc_now(),
      note: nil
    }
  end

  @doc "The line for the run being handed the work (received)."
  def from(role_id, summary) when is_binary(role_id) and is_binary(summary) do
    "[handoff #{@received_marker} #{role_id}] #{summary}"
  end

  @doc "The line for the run handing it over (sent)."
  def to(role_id, summary) when is_binary(role_id) and is_binary(summary) do
    "[handoff #{@sent_marker} #{role_id}] #{summary}"
  end

  @doc """
  Formats a `HandoffLine` struct to string.
  """
  def format(%__MODULE__{direction: :sent, role_id: role_id, summary: summary}) do
    to(role_id, summary)
  end

  def format(%__MODULE__{role_id: role_id, summary: summary}) do
    from(role_id, summary)
  end

  @doc """
  Parses a handoff log line into a `HandoffLine` struct, or returns `nil` for any other line.
  """
  def parse(nil), do: nil

  def parse(line) when is_binary(line) do
    trimmed = String.trim(line)

    cond do
      Regex.match?(@arrow_pattern, trimmed) ->
        [_match, marker, role_id, summary] = Regex.run(@arrow_pattern, trimmed)
        direction = if marker == @received_marker, do: :received, else: :sent

        %__MODULE__{
          role_id: role_id,
          direction: direction,
          summary: String.trim(summary)
        }

      Regex.match?(@colon_pattern, trimmed) ->
        [_match, role_id, summary] = Regex.run(@colon_pattern, trimmed)

        %__MODULE__{
          role_id: role_id,
          direction: :received,
          summary: String.trim(summary)
        }

      Regex.match?(@named_direction_pattern, trimmed) ->
        [_match, dir_str, role_id, summary] = Regex.run(@named_direction_pattern, trimmed)
        direction = if String.downcase(dir_str) == "sent", do: :sent, else: :received

        %__MODULE__{
          role_id: role_id,
          direction: direction,
          summary: String.trim(summary)
        }

      true ->
        nil
    end
  end

  @doc "Returns true if the handoff direction is `:received`."
  def received?(%__MODULE__{direction: :received}), do: true
  def received?(_other), do: false

  @doc "Returns true if the handoff direction is `:sent`."
  def sent?(%__MODULE__{direction: :sent}), do: true
  def sent?(_other), do: false
end
