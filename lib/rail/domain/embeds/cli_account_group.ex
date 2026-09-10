defmodule Rail.Domain.Embeds.CliAccountGroup do
  @moduledoc """
  A group of quota limits or account capabilities reported by a CLI account.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @derive Jason.Encoder

  @primary_key false
  embedded_schema do
    field :name, :string
    field :count, :integer, default: 0
    field :details, :map, default: %{}
  end

  @fields [:name, :count, :details]
  @required_fields [:name]

  @doc "Builds a changeset for a CLI account group."
  def changeset(group, attrs) do
    group
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> validate_number(:count, greater_than_or_equal_to: 0)
  end
end
