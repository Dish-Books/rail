defmodule Rail.Runs.Schemas.RunEvent do
  @moduledoc """
  Schema for an append-only log event emitted during a run.
  """
  use Rail.Schema

  alias Rail.Runs.Schemas.Run

  @primary_key {:id, UXID, autogenerate: true}
  schema "run_events" do
    belongs_to :run, Run
    field :seq, :integer
    field :line, :string

    timestamps()
  end

  @cast_fields [:run_id, :seq, :line]
  @required_fields [:run_id, :seq, :line]

  @doc """
  Builds a changeset for a run event.
  """
  def changeset(run_event, attrs) do
    run_event
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:run_id)
  end
end
