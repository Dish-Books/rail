defmodule Rail.Mcp.Utils.RunToolSaveVerdict do
  @moduledoc """
  Saves a QA pass's verdict, which is also its word that the pass is finished.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaReport
  alias Rail.Pipeline.Schemas.Task

  @fields ["verdict", "summary", "not_checked"]

  @doc """
  Saves the verdict in `arguments` on `task`, or hands back the changeset that
  refused it.
  """
  def run_tool_save_verdict(%Task{} = task, arguments, _opts) do
    with {:ok, %QaReport{verdict: verdict}} <- Pipeline.save_qa_verdict(task, Map.take(arguments, @fields)) do
      {:ok, "Verdict saved: #{QaReport.verdict_label(verdict)}. The pass is finished."}
    end
  end
end
