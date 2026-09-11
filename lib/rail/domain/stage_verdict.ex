defmodule Rail.Domain.StageVerdict do
  @moduledoc """
  What a Reviewer, QA or QA Lead run concluded about the change it looked at.

  This is the shape only. `Rail.Pipeline.Actions.ParseStageVerdict` is what reads
  one out of a run's log.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @derive Jason.Encoder

  @verdicts [:passed, :changes_requested, :unclear]

  @primary_key false
  embedded_schema do
    field :verdict, Ecto.Enum, values: @verdicts, default: :unclear
    field :status, Ecto.Enum, values: @verdicts, default: :unclear
    field :explanation, :string
  end

  @fields [:verdict, :status, :explanation]

  @doc "Builds a changeset for a stage verdict."
  def changeset(stage_verdict, attrs) do
    stage_verdict
    |> cast(attrs, @fields)
    |> validate_required([:verdict])
  end
end
