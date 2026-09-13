defmodule Rail.Pipeline.Schemas.StageVerdict do
  @moduledoc """
  What a run concluded about the work it was doing.

  The gates conclude something about a change they looked at — `:passed` or
  `:changes_requested`. The engineer concludes something about its own work:
  `:done`. `:unclear` is a run that stated nothing, which is how a run that
  stopped halfway is told apart from one that finished.

  This is the shape only. `Rail.Pipeline.Actions.ParseStageVerdict` is what reads
  one out of a run's log.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @derive Jason.Encoder

  @verdicts [:passed, :changes_requested, :done, :unclear]

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
