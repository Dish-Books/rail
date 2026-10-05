defmodule Rail.Mcp.Utils.RunToolSavePlan do
  @moduledoc """
  Saves the architect's plan, from its first draft to its last.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Saves `arguments["plan"]` as `task`'s plan, or hands back the changeset that
  refused it.
  """
  def run_tool_save_plan(%Task{} = task, arguments, _opts) do
    with {:ok, _plan} <- Pipeline.save_plan(task, arguments["plan"]) do
      {:ok, "Plan saved. Save it again after every review comment; the human reads the last save."}
    end
  end
end
