defmodule Rail.Pipeline.Schemas.RunEvent do
  @moduledoc """
  Schema for an append-only log event emitted during a run.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Tools.Schemas.OsProcess

  @primary_key {:id, UXID, autogenerate: true}
  schema "run_events" do
    belongs_to :run, Run
    belongs_to :os_process, OsProcess
    # Assigned by the database, so concurrent writers on one run cannot pick the
    # same position in its log.
    field :seq, :integer, read_after_writes: true
    field :line, :string

    timestamps()
  end

  @cast_fields [:run_id, :os_process_id, :line]
  @required_fields [:run_id, :line]

  @doc """
  Builds a changeset for a run event.
  """
  def changeset(run_event, attrs) do
    run_event
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:os_process_id)
  end
end
