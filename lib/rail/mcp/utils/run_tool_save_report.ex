defmodule Rail.Mcp.Utils.RunToolSaveReport do
  @moduledoc """
  Saves the report of the agent calling it: what the engineer changed, what QA saw or what the code reviewer read.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Saves `arguments["report"]` as the report of the run's role on `task`, or says why it was refused.
  """
  def run_tool_save_report(%Task{} = task, arguments, opts) do
    case Pipeline.save_report(task, Keyword.fetch!(opts, :stage), to_string(arguments["report"])) do
      {:ok, _report} -> {:ok, "Report saved. Saving again replaces it, so the last save is the one that is read."}
      {:error, :empty_report} -> {:refused, "Nothing saved: `report` is empty. Write what you did or saw."}
    end
  end
end
