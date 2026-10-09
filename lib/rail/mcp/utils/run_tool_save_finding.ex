defmodule Rail.Mcp.Utils.RunToolSaveFinding do
  @moduledoc """
  Saves one finding for the Review lead: a new one whole, or a later round's note on one already raised.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.Task

  @fields [
    "key",
    "kind",
    "raised_by",
    "title",
    "problem",
    "file",
    "line",
    "end_line",
    "screen",
    "steps",
    "check",
    "fix",
    "why",
    "rule",
    "places",
    "evidence",
    "severity",
    "recommendation",
    "checklist_rule",
    "status",
    "note"
  ]

  @doc """
  Saves the finding in `arguments` on `task` and says what was saved, or hands back the changeset that
  refused it, naming each field.
  """
  def run_tool_save_finding(%Task{} = task, arguments, _opts) do
    case Pipeline.save_finding(task, Map.take(arguments, @fields)) do
      {:ok, %Finding{key: key, round: round, notes: [_raised]} = finding} ->
        {:ok,
         "Saved finding #{key} (#{finding.severity}) in round #{round} with #{pieces(finding.evidence)} of evidence."}

      {:ok, %Finding{key: key, status: status, carried_round: carried} = finding} ->
        carried = if List.last(finding.notes).kind == :carried, do: " and carried it into round #{carried}", else: ""

        {:ok, "Noted #{key} as #{status}#{carried}. What it said when raised stands."}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp pieces([_one]), do: "1 piece"
  defp pieces(evidence), do: "#{length(evidence)} pieces"
end
