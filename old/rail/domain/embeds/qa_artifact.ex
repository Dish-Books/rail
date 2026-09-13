defmodule Rail.Domain.Embeds.QaArtifact do
  @moduledoc """
  An artifact attached to a QA report row.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @kinds [:image, :video, :text, :log]

  @derive Jason.Encoder

  @primary_key false
  embedded_schema do
    field :name, :string
    field :kind, Ecto.Enum, values: @kinds
    field :text, :string
    field :url, :string
  end

  @fields [:name, :kind, :text, :url]
  @required_fields [:name, :kind]

  @doc "Builds a changeset for a QA artifact."
  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
  end

  def kinds, do: @kinds
end
