defmodule Rail.Domain.Embeds.DemoFrame do
  @moduledoc """
  A single captioned still frame in a recorded walkthrough.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @derive Jason.Encoder

  @primary_key false
  embedded_schema do
    field :url, :string
    field :linear_asset_id, :string
    field :hold_ms, :integer, default: 1000
    field :caption, :string
  end

  @fields [:url, :linear_asset_id, :hold_ms, :caption]
  @required_fields [:url]

  @doc "Builds a changeset for a demo frame."
  def changeset(frame, attrs) do
    frame
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> validate_number(:hold_ms, greater_than: 0)
  end

  @doc "Builds a valid fixture struct for testing."
  def factory do
    %__MODULE__{
      url: "https://linear.app/assets/frame_1.png",
      linear_asset_id: "asset_f1",
      hold_ms: 1000,
      caption: "Sign-in screen displayed"
    }
  end
end
