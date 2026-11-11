defmodule Rail.Issues.Schemas.ClosedCycleIssue do
  @moduledoc """
  An issue a Rail-tracked cycle held when it closed, in the state it had then, so the cycle reads as it closed. Only the
  daily job writes these, all at once.
  """
  use Rail.Schema

  alias Rail.Issues.Schemas.Cycle
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project

  @primary_key {:id, UXID, autogenerate: true, prefix: "ccl"}
  schema "closed_cycle_issues" do
    # The issue's own type, since a coalesce of the two keeps a type only when both sides share it.
    field :state, Ecto.Enum, values: Issue.states()

    belongs_to :project, Project
    belongs_to :cycle, Cycle
    belongs_to :issue, Issue

    timestamps(updated_at: false)
  end
end
