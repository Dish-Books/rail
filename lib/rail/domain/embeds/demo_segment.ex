defmodule Rail.Domain.Embeds.DemoSegment do
  @moduledoc """
  A segment of a recorded demo proving one acceptance criterion.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Rail.Domain.Embeds.DemoFrame

  @derive Jason.Encoder

  @outcomes [:recorded, :not_filmable, :failed]

  @primary_key false
  embedded_schema do
    field :criterion_index, :integer
    field :criterion, :string
    field :outcome, Ecto.Enum, values: @outcomes, default: :recorded
    field :note, :string

    embeds_many :frames, DemoFrame, on_replace: :delete
  end

  @fields [:criterion_index, :criterion, :outcome, :note]
  @required_fields [:criterion_index, :criterion]

  @doc "Builds a changeset for a demo segment."
  def changeset(segment, attrs) do
    segment
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> validate_number(:criterion_index, greater_than_or_equal_to: 1)
    |> cast_embed(:frames, required: false)
  end

  @doc "Returns the total duration in milliseconds across all frames."
  def duration_ms(%__MODULE__{frames: frames}) when is_list(frames) do
    Enum.reduce(frames, 0, fn frame, acc ->
      acc + (frame.hold_ms || 1000)
    end)
  end

  def duration_ms(%__MODULE__{}), do: 0

  @doc "Builds a valid fixture struct for testing."
  def factory do
    %__MODULE__{
      criterion_index: 1,
      criterion: "User can sign in with GitHub",
      outcome: :recorded,
      note: nil,
      frames: [DemoFrame.factory()]
    }
  end
end
