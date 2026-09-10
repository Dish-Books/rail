defmodule Rail.Domain.Embeds.QaRow do
  @moduledoc """
  A single check row in a QA report.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Rail.Domain.Embeds.QaArtifact

  @results [:pass, :fail, :warn, :skip]
  @severities [:blocker, :critical, :major, :minor, :cosmetic]

  @derive Jason.Encoder

  @primary_key false
  embedded_schema do
    field :id, :string
    field :check, :string
    field :result, Ecto.Enum, values: @results
    field :severity, Ecto.Enum, values: @severities
    field :caused_by_change, :boolean, default: true
    field :command, :string
    field :exit_code, :integer
    field :note, :string

    embeds_many :artifacts, QaArtifact, on_replace: :delete
  end

  @fields [
    :id,
    :check,
    :result,
    :severity,
    :caused_by_change,
    :command,
    :exit_code,
    :note
  ]
  @required_fields [:id, :check, :result, :severity]

  @doc "Builds a changeset for a QA row."
  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> cast_embed(:artifacts, required: false)
  end

  @doc "Builds a valid fixture struct for testing."
  def factory do
    %__MODULE__{
      id: "check_1",
      check: "Login flow succeeds",
      result: :pass,
      severity: :blocker,
      caused_by_change: true,
      command: "mix test",
      exit_code: 0,
      note: nil,
      artifacts: [QaArtifact.factory()]
    }
  end

  def results, do: @results
  def severities, do: @severities
end
