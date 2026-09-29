defmodule Rail.Tools.Schemas.Restart do
  @moduledoc """
  One time Rail went down and came back, and how many sandboxes kept running
  through it. `stopped_at` is nil after a crash, when nothing recorded the stop.
  """
  use Rail.Schema

  @primary_key {:id, UXID, autogenerate: true, prefix: "rst"}
  schema "restarts" do
    field :stopped_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :sandboxes_kept, :integer

    timestamps()
  end

  def changeset(restart, attrs) do
    cast(restart, attrs, [:stopped_at, :started_at, :sandboxes_kept])
  end

  @doc "How long Rail was down, in seconds, or nil when either end was not recorded."
  def down_seconds(%__MODULE__{stopped_at: %DateTime{} = stopped_at, started_at: %DateTime{} = started_at}) do
    max(DateTime.diff(started_at, stopped_at, :second), 0)
  end

  def down_seconds(%__MODULE__{}), do: nil
end
