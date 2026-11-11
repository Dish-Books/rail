defmodule Rail.Issues.Schemas.CycleDay do
  @moduledoc """
  A finished day of a Rail-tracked cycle, with its scope, started and completed points as they stood when Rail recorded
  it. Only the daily job writes these, all at once.
  """
  use Rail.Schema

  alias Rail.Issues.Schemas.Cycle

  @primary_key {:id, UXID, autogenerate: true, prefix: "cyd"}
  schema "cycle_days" do
    field :day, :date
    field :scope, :integer
    field :started, :integer
    field :completed, :integer

    belongs_to :cycle, Cycle
  end
end
