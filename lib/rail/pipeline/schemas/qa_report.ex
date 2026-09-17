defmodule Rail.Pipeline.Schemas.QaReport do
  @moduledoc """
  What a QA pass concluded, as it stands on disk. There is no table behind this.

  The findings are rows because a human rules on each of them and that ruling has
  to survive the report being rewritten, a round through the engineer and a round
  through the reviewer. The verdict has nothing to survive: it belongs to one
  pass, the next pass replaces all of it, and nothing queries, filters or orders
  by it. So it is read off the report whenever the panel draws, the way the
  approved design is.

  That does mean the verdict is not history. Once the task is cleaned up the
  report goes with the scratch directory, and a merged task can no longer be
  asked what QA said about it. The same is already true of the design and its
  screenshots.

  The verdict is a judgement rather than a tally of the findings: three majors
  that were all broken before this change is a pass, and one minor that makes the
  feature unusable is a fail. It is advice, though - what the human decides about
  each finding is what actually moves the task.
  """
  use Rail.Schema

  @verdicts [:pass, :concerns, :fail]

  @primary_key false
  embedded_schema do
    field :verdict, Ecto.Enum, values: @verdicts
    field :summary, :string
    field :not_checked, :string
    field :findings, {:array, :map}, default: []
  end

  def verdicts, do: @verdicts

  def verdict_label(:pass), do: "Passed"
  def verdict_label(:concerns), do: "Passed with concerns"
  def verdict_label(:fail), do: "Failed"
end
