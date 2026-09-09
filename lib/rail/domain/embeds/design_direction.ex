defmodule Rail.Domain.Embeds.DesignDirection do
  @moduledoc """
  An individual design direction explored by the designer.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @derive Jason.Encoder

  @primary_key false
  embedded_schema do
    field :key, :string
    field :title, :string
    field :notes, :string
    field :still_url, :string
    field :linear_asset_id, :string
  end

  @fields [:key, :title, :notes, :still_url, :linear_asset_id]
  @required_fields [:key, :title]

  @doc "Builds a changeset for a design direction."
  def changeset(direction, attrs) do
    direction
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
  end

  @doc "Builds a valid fixture struct for testing."
  def factory do
    %__MODULE__{
      key: "direction_a",
      title: "Direction A",
      notes: "Minimalist modern UI",
      still_url: "https://linear.app/assets/still_a.png",
      linear_asset_id: "asset_dir_a"
    }
  end
end
