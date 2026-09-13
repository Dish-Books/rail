defmodule Rail.Artifacts.Schemas.Demo do
  @moduledoc """
  Schema for a recorded walkthrough demo artifact.
  """
  use Rail.Schema

  alias Rail.Domain.Embeds.DemoSegment

  @outcomes ["recorded", "declined", "failed"]

  @primary_key {:id, UXID, autogenerate: true, prefix: "dmo"}
  schema "demos" do
    field :task_id, UXID
    field :version, :integer, default: 1
    field :recorded_at, :utc_datetime_usec
    field :commit, :string
    field :head_sha, :string
    field :dirty_digest, :string
    field :outcome, :string
    field :note, :string
    field :stale, :boolean, default: false
    field :linear_comment_id, :string

    embeds_many :segments, DemoSegment, on_replace: :delete

    timestamps()
  end

  @cast_fields [
    :task_id,
    :version,
    :recorded_at,
    :commit,
    :head_sha,
    :dirty_digest,
    :outcome,
    :note,
    :stale,
    :linear_comment_id
  ]
  @required_fields [:task_id, :version, :recorded_at, :outcome]

  @doc "Builds a changeset for a demo artifact."
  def changeset(demo, attrs) do
    demo
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:outcome, @outcomes)
    |> validate_number(:version, greater_than_or_equal_to: 1)
    |> cast_embed(:segments)
    |> unique_constraint([:task_id, :version])
  end
end
