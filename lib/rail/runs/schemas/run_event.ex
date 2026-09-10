defmodule Rail.Runs.Schemas.RunEvent do
  @moduledoc """
  Schema for an append-only log event emitted during a role run.
  """
  use Rail.Schema

  alias Rail.Runs.Schemas.RoleRun

  @primary_key {:id, UXID, autogenerate: true}
  schema "run_events" do
    belongs_to :role_run, RoleRun
    field :seq, :integer
    field :line, :string

    timestamps()
  end

  @cast_fields [:role_run_id, :seq, :line]
  @required_fields [:role_run_id, :seq, :line]

  @doc """
  Builds a changeset for a run event.
  """
  def changeset(run_event, attrs) do
    run_event
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:role_run_id)
  end

  @doc """
  Builds a valid fixture struct for tests.
  """
  def factory do
    %__MODULE__{
      role_run_id: UXID.generate!(prefix: "rr"),
      seq: 1,
      line: ~s({"type":"init"})
    }
  end
end
