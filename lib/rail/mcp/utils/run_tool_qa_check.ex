defmodule Rail.Mcp.Utils.RunToolQaCheck do
  @moduledoc """
  Marks one row of a QA pass's checklist as run.

  Called as the pass reaches the row rather than at the end, so it does not touch
  the browser either. Everything an agent can get wrong is refused in a sentence
  it can act on: a key that is not on the list, and an outcome Rail does not know.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaCheck
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Records the outcome in `arguments` against the row it names on `task`.
  """
  def run_tool_qa_check(%Task{} = task, %{"key" => key, "outcome" => outcome} = arguments, _opts) do
    case Pipeline.record_qa_check(task, key, outcome, arguments["note"]) do
      {:ok, check} -> {:ok, "#{check.key}: #{QaCheck.outcome_label(check.outcome)}."}
      {:error, :qa_checklist_not_found} -> {:refused, "There is no checklist yet. Call qa_plan first."}
      {:error, :qa_check_not_found} -> {:refused, "No check called #{inspect(key)} is on the checklist."}
      {:error, :unusable_outcome} -> {:refused, "`outcome` is `pass`, `fail` or `skipped`. Nothing was recorded."}
    end
  end

  def run_tool_qa_check(%Task{}, _arguments, _opts) do
    {:refused, "qa_check needs a `key` and an `outcome`. Nothing was recorded."}
  end
end
