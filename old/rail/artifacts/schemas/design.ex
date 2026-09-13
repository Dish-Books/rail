defmodule Rail.Artifacts.Schemas.Design do
  @moduledoc """
  Schema for a design artifact exploring multiple UI/UX directions.
  """
  use Rail.Schema

  alias Rail.Domain.Embeds.DesignDirection

  @primary_key {:id, UXID, autogenerate: true, prefix: "dsg"}
  schema "designs" do
    field :task_id, UXID
    field :version, :integer, default: 1
    field :canvas_url, :string
    field :picked_key, :string
    field :linear_comment_id, :string

    embeds_many :directions, DesignDirection, on_replace: :delete

    timestamps()
  end

  @cast_fields [:task_id, :version, :canvas_url, :picked_key, :linear_comment_id]
  @required_fields [:task_id, :version, :canvas_url]

  @doc "Builds a changeset for a design artifact."
  def changeset(design, attrs) do
    design
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_number(:version, greater_than_or_equal_to: 1)
    |> cast_embed(:directions)
    |> unique_constraint([:task_id, :version])
  end
end
