defmodule Rail.Pipeline.Schemas.FindingNote do
  @moduledoc """
  One dated entry in a finding's history, in the round it happened: its raising, a pass's verdict on it, a
  ruling and who made it, a fix, or being carried into a later round. A fix names the places it covered or
  left and the test that failed first.
  """
  use Rail.Schema

  @kinds [:raised, :pass, :ruling, :fix, :carried]

  @primary_key false
  embedded_schema do
    field :round, :integer
    field :kind, Ecto.Enum, values: @kinds
    field :at, :utc_datetime_usec
    field :commit, :string
    field :status, Ecto.Enum, values: [:open, :fixed, :not_fixed]
    field :decision, Ecto.Enum, values: [:fix, :skip]
    field :by_id, :string
    field :text, :string
    field :covered, {:array, :string}, default: []
    field :left, {:array, :string}, default: []
    field :test, :string
  end

  @doc """
  Builds a changeset for one note. A pass's own words are held to 300 characters, as the brief says.
  """
  def changeset(note, attrs) do
    note
    |> cast(attrs, [:round, :kind, :at, :commit, :status, :decision, :by_id, :text, :covered, :left, :test])
    |> validate_required([:round, :kind, :at])
    |> validate_number(:round, greater_than: 0)
    |> validate_length(:text, max: 300)
  end
end
