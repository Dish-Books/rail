defmodule Rail.Mcp.Utils.RunToolSaveFinding do
  @moduledoc """
  Saves one finding for review or for QA: both call `save_finding`, with their own
  fields, so the run's stage says which.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaFinding
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Pipeline.Schemas.Task

  @review ["key", "title", "detail", "suggestion", "file", "line", "severity", "recommendation", "status"]

  @qa [
    "key",
    "title",
    "check",
    "criterion",
    "screen",
    "steps",
    "expected",
    "observed",
    "detail",
    "suggestion",
    "severity",
    "recommendation",
    "caused_by_change",
    "status",
    "evidence"
  ]

  @doc """
  Saves the finding in `arguments` on `task` for `opts[:stage]` and says what
  was saved, or hands back the changeset that refused it.
  """
  def run_tool_save_finding(%Task{} = task, arguments, opts) do
    case Keyword.fetch!(opts, :stage) do
      :review -> task |> Pipeline.save_review_finding(Map.take(arguments, @review)) |> saved()
      :qa -> task |> Pipeline.save_qa_finding(Map.take(arguments, @qa)) |> saved()
    end
  end

  defp saved({:ok, %ReviewFinding{key: key, severity: severity}}), do: {:ok, "Saved finding #{key} (#{severity})."}

  defp saved({:ok, %QaFinding{key: key, severity: severity, evidence: evidence}}) do
    {:ok,
     "Saved finding #{key} (#{severity}) with #{length(evidence)} piece#{if length(evidence) == 1, do: "", else: "s"} of evidence."}
  end

  defp saved({:error, changeset}), do: {:error, changeset}
end
