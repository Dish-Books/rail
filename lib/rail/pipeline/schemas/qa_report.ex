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
  @verdicts [:pass, :concerns, :fail]
  @evidence_reminder_limit 2

  # A plain struct rather than an embedded schema: nothing casts this, nothing
  # queries it, and the only thing that builds one is the reader, which has
  # already checked the verdict against the list below.
  defstruct [:verdict, :summary, :not_checked, findings: []]

  def verdicts, do: @verdicts

  @doc "How many times Rail sends a report back for evidence before it stops asking."
  def evidence_reminder_limit, do: @evidence_reminder_limit

  def verdict_label(:pass), do: "Passed"
  def verdict_label(:concerns), do: "Passed with concerns"
  def verdict_label(:fail), do: "Failed"

  @doc """
  Every finding in `report` left with no evidence, as `%{key:, title:, refused:}`
  in report order. Any one of them makes the whole report not valid.
  """
  def unproven(%__MODULE__{findings: findings}) do
    for %{evidence: [], key: key, title: title, refused: refused} <- findings,
        do: %{key: key, title: title, refused: refused}
  end
end
